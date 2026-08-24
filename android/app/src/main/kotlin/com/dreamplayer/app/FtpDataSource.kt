package com.dreamplayer.app

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSpec
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSch
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import java.io.InputStream
import java.util.Properties

/// ExoPlayer DataSource for `ftp://` and `sftp://` URIs (see [FtpClient]).
///
/// URIs look like `ftp://<serverId>/<remotePath>` or `sftp://<serverId>/<path>`;
/// the `<serverId>` resolves to the saved server + EncryptedSharedPreferences
/// credentials in [FtpClient.FtpStore]. Each open creates its own connection
/// (simple + robust to NAS sleep). Seeking re-opens with `REST` / SFTP resume
/// offset, so ExoPlayer's extractor can probe freely.
@UnstableApi
class FtpDataSource(private val context: Context) : BaseDataSource(true) {

    private var openedUri: Uri? = null
    private var input: InputStream? = null
    private var ftpClient: FTPClient? = null
    private var sftpSession: com.jcraft.jsch.Session? = null
    private var sftpChannel: ChannelSftp? = null
    private var isSftp = false
    private var fileSize: Long = C.LENGTH_UNSET.toLong()
    private var bytesRemaining: Long = C.LENGTH_UNSET.toLong()
    private var position: Long = 0
    private var remotePath: String = ""

    override fun open(dataSpec: DataSpec): Long {
        val uri = dataSpec.uri
        openedUri = uri
        isSftp = uri.scheme.equals("sftp", ignoreCase = true)
        val serverId = uri.host ?: throw java.io.IOException("Malformed FTP uri: $uri")
        val rawPath = uri.path ?: "/"
        // Uri.path is already percent-decoded by Android; re-decode is not needed.
        remotePath = if (rawPath.isEmpty()) "/" else rawPath
        val creds = FtpClient.FtpStore.resolve(context, serverId)
            ?: throw java.io.IOException("Unknown FTP server '$serverId'")

        transferInitializing(dataSpec)
        position = dataSpec.position

        try {
            if (isSftp) {
                openSftp(creds, dataSpec)
            } else {
                openFtp(creds, dataSpec)
            }
        } catch (e: Exception) {
            closeInternal()
            throw java.io.IOException("FTP open failed: ${e.message}", e)
        }

        val length = if (dataSpec.length != C.LENGTH_UNSET.toLong()) dataSpec.length
        else if (fileSize != C.LENGTH_UNSET.toLong()) fileSize - dataSpec.position
        else C.LENGTH_UNSET.toLong()
        bytesRemaining = length
        transferStarted(dataSpec)
        return length
    }

    private fun openFtp(creds: FtpClient.FtpServer, dataSpec: DataSpec) {
        val ftp = FTPClient().apply {
            connectTimeout = 10000
            defaultTimeout = 15000
        }
        ftp.connect(creds.host, creds.port)
        val user = creds.username.ifEmpty { "anonymous" }
        val pass = creds.password.ifEmpty { "anonymous@" }
        if (!ftp.login(user, pass)) {
            ftp.disconnect()
            throw java.io.IOException("FTP login failed")
        }
        ftp.enterLocalPassiveMode()
        ftp.setFileType(FTP.BINARY_FILE_TYPE)

        // File size via parent listing (SIZE command is not always supported).
        fileSize = ftpFileSize(ftp, remotePath)

        if (dataSpec.position > 0) {
            ftp.setRestartOffset(dataSpec.position)
        }
        val stream = ftp.retrieveFileStream(remotePath)
            ?: run {
                try { ftp.logout() } catch (_: Exception) {}
                try { ftp.disconnect() } catch (_: Exception) {}
                throw java.io.IOException("FTP retrieve failed for $remotePath: ${ftp.replyString}")
            }
        ftpClient = ftp
        input = stream
    }

    private fun openSftp(creds: FtpClient.FtpServer, dataSpec: DataSpec) {
        val jsch = JSch()
        val session = jsch.getSession(creds.username.ifEmpty { "anonymous" }, creds.host, creds.port)
        if (creds.password.isNotEmpty()) session.setPassword(creds.password)
        val config = Properties()
        config["StrictHostKeyChecking"] = "no"
        session.setConfig(config)
        session.timeout = 10000
        session.connect(10000)
        val channel = session.openChannel("sftp") as ChannelSftp
        channel.connect(5000)
        fileSize = try {
            channel.lstat(remotePath).size
        } catch (_: Exception) {
            C.LENGTH_UNSET.toLong()
        }
        val stream: InputStream = if (dataSpec.position > 0) {
            channel.get(remotePath, null, dataSpec.position)
        } else {
            channel.get(remotePath)
        }
        sftpSession = session
        sftpChannel = channel
        input = stream
    }

    private fun ftpFileSize(ftp: FTPClient, path: String): Long {
        // Try SIZE command first (some servers support it).
        try {
            ftp.sendCommand("SIZE", path)
            if (ftp.replyCode == 213) {
                return ftp.replyString.trim().substringAfter("213").trim().toLongOrNull()
                    ?: C.LENGTH_UNSET.toLong()
            }
        } catch (_: Exception) {}
        // Fallback: list parent and match name.
        return try {
            val parent = path.substringBeforeLast('/', "")
            val name = path.substringAfterLast('/')
            val dir = if (parent.isEmpty()) "/" else parent
            val files = ftp.listFiles(dir)
            files.firstOrNull { it.name == name }?.size ?: C.LENGTH_UNSET.toLong()
        } catch (_: Exception) {
            C.LENGTH_UNSET.toLong()
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT
        val toRead = if (bytesRemaining == C.LENGTH_UNSET.toLong()) length
        else minOf(length.toLong(), bytesRemaining).toInt()
        val inp = input ?: return C.RESULT_END_OF_INPUT
        val n = inp.read(buffer, offset, toRead)
        if (n == -1) {
            if (bytesRemaining == C.LENGTH_UNSET.toLong()) return C.RESULT_END_OF_INPUT
            return C.RESULT_END_OF_INPUT
        }
        if (bytesRemaining != C.LENGTH_UNSET.toLong()) bytesRemaining -= n
        position += n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = openedUri

    override fun close() {
        closeInternal()
        openedUri = null
    }

    private fun closeInternal() {
        try { input?.close() } catch (_: Exception) {}
        input = null
        if (isSftp) {
            try { sftpChannel?.disconnect() } catch (_: Exception) {}
            sftpChannel = null
            try { sftpSession?.disconnect() } catch (_: Exception) {}
            sftpSession = null
        } else {
            val ftp = ftpClient
            ftpClient = null
            if (ftp != null) {
                try {
                    // Must complete pending command after closing the data stream.
                    if (ftp.isConnected) {
                        try { input?.close() } catch (_: Exception) {}
                        ftp.completePendingCommand()
                    }
                } catch (_: Exception) {}
                try { ftp.logout() } catch (_: Exception) {}
                try { ftp.disconnect() } catch (_: Exception) {}
            }
        }
        fileSize = C.LENGTH_UNSET.toLong()
        bytesRemaining = C.LENGTH_UNSET.toLong()
    }
}
