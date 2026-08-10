package com.example.dream_player

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.fileinformation.FileStandardInformation
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2CreateOptions
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File
import java.io.IOException
import java.util.EnumSet
import java.util.concurrent.TimeUnit

/// ExoPlayer DataSource that streams a file straight off an SMB share
/// (no local download). URIs look like `smb://<serverId>/<share>/<path...>`;
/// the `<serverId>` resolves to the saved server + encrypted credentials in
/// [SmbStore], so passwords never appear in the URI or on the Dart side.
///
/// Each open() makes a fresh connection and keeps a positioned [File] handle,
/// so seeks just issue SMB2 read requests at the requested offset.
@UnstableApi
class SmbDataSourceFactory(private val context: Context) : DataSource.Factory {
    override fun createDataSource(): DataSource = SmbDataSource(context)
}

@UnstableApi
class SmbDataSource(private val context: Context) : BaseDataSource(true) {

    private var client: com.hierynomus.smbj.SMBClient? = null
    private var connection: Connection? = null
    private var session: Session? = null
    private var share: DiskShare? = null
    private var file: File? = null
    private var position: Long = 0
    private var openedUri: Uri? = null

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        openedUri = dataSpec.uri
        val uri = dataSpec.uri
        val serverId = uri.host
            ?: throw IOException("Malformed SMB uri: $uri")
        val segments = uri.pathSegments
        if (segments.isEmpty()) throw IOException("Missing share in SMB uri: $uri")
        val shareName = segments[0]
        val remotePath =
            if (segments.size > 1) segments.subList(1, segments.size).joinToString("/") else ""

        val creds = SmbStore.resolve(context, serverId)
            ?: throw IOException("Unknown SMB server '$serverId'")

        try {
            val client = com.hierynomus.smbj.SMBClient(
                SmbConfig.builder().withTimeout(30, TimeUnit.SECONDS).build(),
            )
            val connection = client.connect(creds.host, creds.port)
            val session = connection.authenticate(creds.authContext())
            val share = session.connectShare(shareName) as DiskShare
            val file = share.openFile(
                remotePath,
                EnumSet.of(AccessMask.GENERIC_READ),
                null,
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN,
                EnumSet.of(SMB2CreateOptions.FILE_RANDOM_ACCESS),
            )
            this.client = client
            this.connection = connection
            this.session = session
            this.share = share
            this.file = file
            position = dataSpec.position
            val size = file.getFileInformation(FileStandardInformation::class.java).endOfFile
            val length =
                if (dataSpec.length != C.LENGTH_UNSET.toLong())
                    dataSpec.length
                else
                    size - dataSpec.position
            transferStarted(dataSpec)
            return length
        } catch (e: Exception) {
            close()
            throw IOException("SMB open failed: ${e.message}", e)
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val f = file ?: return C.RESULT_END_OF_INPUT
        if (length == 0) return 0
        val n = f.read(buffer, position, offset, length)
        if (n < 0) return C.RESULT_END_OF_INPUT
        position += n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = openedUri

    override fun close() {
        try { file?.close() } catch (_: Exception) {}
        file = null
        try { share?.close() } catch (_: Exception) {}
        share = null
        try { connection?.close() } catch (_: Exception) {}
        connection = null
        try { client?.close() } catch (_: Exception) {}
        client = null
        position = 0
        openedUri = null
    }
}
