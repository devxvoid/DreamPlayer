package com.example.dream_player

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.msfscc.fileinformation.FileIdBothDirectoryInformation
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2CreateOptions
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// Credentials bundle for one SMB server, used both by the browser and the
/// ExoPlayer streaming data source.
data class SmbCredentials(
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val domain: String,
    val anonymous: Boolean,
) {
    fun authContext(): AuthenticationContext = if (anonymous) {
        AuthenticationContext.anonymous()
    } else {
        AuthenticationContext(username, password.toCharArray(), domain)
    }
}

/// AES-GCM (AndroidKeyStore) password encryption so SMB passwords are never
/// stored in plaintext — they stay encrypted in SharedPreferences.
private object SmbCrypto {
    private const val ALIAS = "dreamplayer_smb_key"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        if (!ks.containsAlias(ALIAS)) {
            val gen = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                "AndroidKeyStore",
            )
            gen.init(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            gen.generateKey()
        }
        return ks.getKey(ALIAS, null) as SecretKey
    }

    fun encrypt(plain: String): String? = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val enc = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(iv + enc, Base64.NO_WRAP)
    } catch (_: Exception) {
        null
    }

    fun decrypt(encoded: String): String? = try {
        val raw = Base64.decode(encoded, Base64.NO_WRAP)
        val iv = raw.copyOfRange(0, 12)
        val data = raw.copyOfRange(12, raw.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        String(cipher.doFinal(data), Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }
}

/// Server list + encrypted credentials, shared between the browse UI and the
/// ExoPlayer `SmbDataSource` (which resolves `smb://<serverId>/...` URIs).
object SmbStore {

    private const val PREFS = "dreamplayer_smb"
    private const val KEY_SERVERS = "servers"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun servers(context: Context): List<JSONObject> {
        val raw = prefs(context).getString(KEY_SERVERS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun serverById(context: Context, id: String): JSONObject? =
        servers(context).firstOrNull { it.optString("id") == id }

    fun save(context: Context, server: JSONObject) {
        val id = server.optString("id").ifEmpty { UUID.randomUUID().toString() }
        server.put("id", id)
        val list = servers(context).filterNot { it.optString("id") == id }.toMutableList()
        list.add(server)
        prefs(context).edit().putString(KEY_SERVERS, JSONArray(list).toString()).apply()
    }

    fun delete(context: Context, id: String) {
        val list = servers(context).filterNot { it.optString("id") == id }
        prefs(context).edit().putString(KEY_SERVERS, JSONArray(list).toString()).apply()
    }

    /// Manually-added share names (smbj can't enumerate a server's shares —
    /// SMB2 has no NetShareEnum; we probe well-known names instead).
    fun shares(context: Context, serverId: String): List<String> {
        val raw = prefs(context).getString("shares_$serverId", null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getString(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun addShare(context: Context, serverId: String, shareName: String): Boolean {
        val list = shares(context, serverId).toMutableSet()
        val added = list.add(shareName)
        if (added) {
            prefs(context)
                .edit()
                .putString("shares_$serverId", JSONArray(list.toList()).toString())
                .apply()
        }
        return added
    }

    /// Resolves an `smb://<serverId>/...` URI back to a credential bundle.
    fun resolve(context: Context, serverId: String): SmbCredentials? {
        val s = serverById(context, serverId) ?: return null
        val password = s.optString("passwordEnc").ifEmpty { "" }
            .let { if (it.isEmpty()) "" else SmbCrypto.decrypt(it) ?: "" }
        return SmbCredentials(
            host = s.optString("host"),
            port = s.optInt("port", 445),
            username = s.optString("username"),
            password = password,
            domain = s.optString("domain"),
            anonymous = s.optBoolean("anonymous"),
        )
    }

    fun toMap(server: JSONObject): Map<String, Any?> = mapOf(
        "id" to server.optString("id"),
        "name" to server.optString("name"),
        "host" to server.optString("host"),
        "port" to server.optInt("port", 445),
        "username" to server.optString("username"),
        "domain" to server.optString("domain"),
        "anonymous" to server.optBoolean("anonymous"),
        "hasPassword" to (server.optString("passwordEnc").isNotEmpty()),
    )
}

/// SMB2/3 browse client exposed over the `dreamplayer/smb` MethodChannel.
///
/// Each call makes a fresh connection (simple + robust to NAS sleep); the
/// roadmap's reconnect/reuse is a later refinement.
class SMBClient(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/smb"

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
        )

        /// Share names probed on every server browse, since SMB2 can't
        /// enumerate shares. NAS boxes (Synology/QNAP/OpenMediaVault/Windows)
        /// almost always expose one of these.
        private val COMMON_SHARES = listOf(
            "videos", "video", "movies", "movie", "tv", "tvshows", "series",
            "media", "downloads", "download", "public", "share", "shares",
            "shared", "files", "home", "homes", "music", "photos", "photo",
            "Documents", "Desktop",
        )
    }

    private val executor = Executors.newSingleThreadExecutor()

    private val config = SmbConfig.builder()
        .withTimeout(15, TimeUnit.SECONDS)
        .build()

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listServers" -> result.success(SmbStore.servers(context).map(SmbStore::toMap))
                "saveServer" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("bad_args", "Missing server", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(saveServer(args))
                            } catch (e: Exception) {
                                result.error("save_failed", e.message, null)
                            }
                        }
                    }
                }
                "deleteServer" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("bad_args", "Missing id", null)
                    } else {
                        SmbStore.delete(context, id)
                        result.success(null)
                    }
                }
                "testConnection" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("bad_args", "Missing params", null)
                    } else {
                        executor.execute {
                            result.success(testConnection(args))
                        }
                    }
                }
                "listShares" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("bad_args", "Missing id", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(listShares(id))
                            } catch (e: Exception) {
                                result.error("smb_error", e.message, null)
                            }
                        }
                    }
                }
                "addShare" -> {
                    val id = call.argument<String>("id")
                    val shareName = call.argument<String>("share")
                    if (id == null || shareName.isNullOrBlank()) {
                        result.error("bad_args", "Missing id or share", null)
                    } else {
                        result.success(SmbStore.addShare(context, id, shareName.trim()))
                    }
                }
                "listDirectory" -> {
                    val id = call.argument<String>("id")
                    val shareName = call.argument<String>("share")
                    val path = call.argument<String>("path") ?: ""
                    if (id == null || shareName == null) {
                        result.error("bad_args", "Missing id or share", null)
                    } else {
                        executor.execute {
                            try {
                                result.success(listDirectory(id, shareName, path))
                            } catch (e: Exception) {
                                result.error("smb_error", e.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveServer(args: Map<*, *>): Map<String, Any?> {
        val id = args["id"] as? String
        val server = SmbStore.serverById(context, id ?: "")?.let { JSONObject(it.toString()) }
            ?: JSONObject()
        val host = (args["host"] as? String)?.trim().orEmpty()
        require(host.isNotEmpty()) { "Host is required" }
        val password = (args["password"] as? String).orEmpty()
        val name = (args["name"] as? String)?.trim()
        server.put("name", if (name.isNullOrEmpty()) host else name)
        server.put("host", host)
        server.put("port", (args["port"] as? Number)?.toInt() ?: 445)
        server.put("domain", (args["domain"] as? String).orEmpty())
        server.put("username", (args["username"] as? String).orEmpty())
        server.put("anonymous", args["anonymous"] == true)
        if (args.containsKey("password") && password.isNotEmpty()) {
            server.put("passwordEnc", SmbCrypto.encrypt(password) ?: "")
        } else if (!args.containsKey("password")) {
            // keep existing stored password on partial updates
        }
        SmbStore.save(context, server)
        return SmbStore.toMap(server)
    }

    private fun testConnection(args: Map<*, *>): Map<String, Any?> {
        val host = (args["host"] as? String)?.trim().orEmpty()
        return try {
            require(host.isNotEmpty()) { "Host is required" }
            val creds = SmbCredentials(
                host = host,
                port = (args["port"] as? Number)?.toInt() ?: 445,
                username = (args["username"] as? String).orEmpty(),
                password = (args["password"] as? String).orEmpty(),
                domain = (args["domain"] as? String).orEmpty(),
                anonymous = args["anonymous"] == true,
            )
            withConnection(creds) { _ -> }
            mapOf("ok" to true, "error" to null)
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to (e.message ?: "Connection failed"))
        }
    }

    private fun listShares(serverId: String): List<Map<String, Any?>> {
        val creds = SmbStore.resolve(context, serverId)
            ?: throw IllegalStateException("Unknown server")
        return withConnection(creds) { session ->
            val names = mutableSetOf<String>()
            names.addAll(SmbStore.shares(context, serverId))
            for (name in COMMON_SHARES) {
                try {
                    val share = session.connectShare(name)
                    if (share is DiskShare) {
                        names.add(name)
                    }
                    share.close()
                } catch (_: Exception) {
                    // not a disk share / no access — skip
                }
            }
            names.sortedBy { it.lowercase(Locale.ROOT) }
                .map { name ->
                    mapOf(
                        "name" to name,
                        "path" to name,
                        "isDirectory" to true,
                        "size" to 0L,
                        "modified" to 0L,
                    )
                }
        }
    }

    private fun listDirectory(
        serverId: String,
        shareName: String,
        path: String,
    ): List<Map<String, Any?>> {
        val creds = SmbStore.resolve(context, serverId)
            ?: throw IllegalStateException("Unknown server")
        return withConnection(creds) { session ->
            val share = session.connectShare(shareName) as DiskShare
            val entries = share.list(path)
            val dirs = mutableListOf<Map<String, Any?>>()
            val files = mutableListOf<Map<String, Any?>>()
            for (f in entries) {
                val name = f.fileName
                if (name == "." || name == "..") continue
                val isDir =
                    (f.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value) != 0L
                val entry = mapOf(
                    "name" to name,
                    "path" to if (path.isEmpty()) name else "$path/$name",
                    "isDirectory" to isDir,
                    "size" to f.endOfFile,
                    "modified" to (f.lastWriteTime?.toEpochMillis() ?: 0L),
                )
                if (isDir) dirs.add(entry) else if (isVideo(name)) files.add(entry)
            }
            dirs.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
            files.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
            dirs + files
        }
    }

    private fun isVideo(name: String): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return false
        return name.substring(dot + 1).lowercase(Locale.ROOT) in VIDEO_EXTENSIONS
    }

    /// Opens a fresh SMB connection+session, runs [block], then tears it down.
    /// Closing the [Connection] also closes any connected shares/sessions.
    private fun <T> withConnection(
        creds: SmbCredentials,
        block: (Session) -> T,
    ): T {
        val client = com.hierynomus.smbj.SMBClient(config)
        try {
            val connection = client.connect(creds.host, creds.port)
            try {
                val session = connection.authenticate(creds.authContext())
                return block(session)
            } finally {
                connection.close()
            }
        } finally {
            client.close()
        }
    }
}
