package com.dreamplayer.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.UUID

/// In-app file browser (CX-Explorer style) backed by direct filesystem access.
/// Requires MANAGE_EXTERNAL_STORAGE on Android 11+; folders picked via the
/// system document picker (ACTION_OPEN_DOCUMENT_TREE) stay browsable through
/// persistable URI grants without needing all-files access.
class FileBrowser(private val activity: MainActivity) {

    companion object {
        const val CHANNEL = "dreamplayer/files"
        const val REQ_PICK_FOLDER = 9001

        private const val PREFS = "dreamplayer.folderBookmarks"
        private const val BOOKMARK_PREFIX = "bm."
        private const val TREE_PREFIX = "tree:"

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
        )
    }

    private var pendingFolderResult: MethodChannel.Result? = null

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "openAllFilesAccessSettings" -> {
                    openAllFilesAccessSettings()
                    result.success(null)
                }
                "getStorageRoots" -> result.success(storageRoots())
                "listDirectory" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "Missing path", null)
                    } else {
                        result.success(listDirectory(path))
                    }
                }
                "pickFolder" -> pickFolder(result)
                "resolveImportedPath" -> result.success(true)
                "removeBookmark" -> {
                    val id = call.argument<String>("bookmarkId")
                    if (id != null) removeBookmark(id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()

    private fun openAllFilesAccessSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val intent = Intent(
            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:${activity.packageName}"),
        )
        try {
            activity.startActivity(intent)
        } catch (_: Exception) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    // MARK: - Roots

    private fun storageRoots(): List<Map<String, Any?>> {
        val roots = mutableListOf<Map<String, Any?>>()
        Environment.getExternalStorageDirectory()?.let { internal ->
            roots.add(rootEntry(internal.absolutePath, "Internal storage"))
        }
        File("/storage").takeIf { it.isDirectory }?.listFiles()?.forEach { vol ->
            if (vol.isDirectory && vol.name != "emulated" && vol.name != "self" &&
                !vol.name.startsWith("usb")
            ) {
                roots.add(rootEntry(vol.absolutePath, "SD card (${vol.name})"))
            }
        }
        roots.addAll(bookmarkEntries())
        return roots
    }

    private fun rootEntry(path: String, name: String): Map<String, Any?> = mapOf(
        "name" to name,
        "path" to path,
        "isDirectory" to true,
        "size" to 0L,
    )

    // MARK: - Listing

    private fun listDirectory(path: String): List<Map<String, Any?>> =
        if (path.startsWith(TREE_PREFIX)) listTreeDirectory(path)
        else listFileDirectory(path)

    private fun listFileDirectory(path: String): List<Map<String, Any?>> {
        val dir = File(path)
        if (!dir.exists() || !dir.isDirectory) {
            return listOf(mapOf("error" to "not_found", "path" to path))
        }
        val entries = dir.listFiles() ?: return emptyList()
        val dirs = mutableListOf<Map<String, Any?>>()
        val files = mutableListOf<Map<String, Any?>>()
        for (f in entries) {
            val name = f.name
            if (name.startsWith(".")) continue
            if (f.isDirectory) {
                dirs.add(entry(f, isDirectory = true))
            } else if (isVideo(name)) {
                files.add(entry(f, isDirectory = false))
            }
        }
        dirs.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        files.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        return dirs + files
    }

    /// Lists a bookmarked tree (`tree:<id>` or `tree:<id>/<relative/path>`).
    /// Directory entries carry the synthetic `tree:` path for navigation; video
    /// files carry their `content://` document URI so playback works through the
    /// player's `uri` path.
    private fun listTreeDirectory(path: String): List<Map<String, Any?>> {
        val (id, relative) = parseTreePath(path)
        val treeUri = treeUriFor(id)
            ?: return listOf(mapOf("error" to "not_found", "path" to path))
        var doc = DocumentFile.fromTreeUri(activity, treeUri)
            ?: return listOf(mapOf("error" to "not_found", "path" to path))
        if (relative.isNotEmpty()) {
            for (segment in relative.split('/')) {
                if (segment.isEmpty()) continue
                doc = doc.findFile(segment)
                    ?: return listOf(mapOf("error" to "not_found", "path" to path))
            }
        }
        if (!doc.isDirectory) return listOf(mapOf("error" to "not_found", "path" to path))
        val base = if (relative.isEmpty()) treePath(id) else "${treePath(id)}/$relative"
        val dirs = mutableListOf<Map<String, Any?>>()
        val files = mutableListOf<Map<String, Any?>>()
        for (child in doc.listFiles()) {
            val name = child.name ?: continue
            if (name.startsWith(".")) continue
            if (child.isDirectory) {
                dirs.add(
                    mapOf(
                        "name" to name,
                        "path" to "$base/$name",
                        "isDirectory" to true,
                        "size" to 0L,
                    ),
                )
            } else if (isVideo(name)) {
                files.add(
                    mapOf(
                        "name" to name,
                        "path" to child.uri.toString(),
                        "isDirectory" to false,
                        "size" to child.length(),
                    ),
                )
            }
        }
        dirs.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        files.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        return dirs + files
    }

    private fun isVideo(name: String): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return false
        return name.substring(dot + 1).lowercase(Locale.ROOT) in VIDEO_EXTENSIONS
    }

    private fun entry(f: File, isDirectory: Boolean): Map<String, Any?> = mapOf(
        "name" to f.name,
        "path" to f.absolutePath,
        "isDirectory" to isDirectory,
        "size" to if (isDirectory) 0L else f.length(),
    )

    // MARK: - Bookmarks

    private fun bookmarks(): SharedPreferences =
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun keyFor(id: String) = BOOKMARK_PREFIX + id

    private fun treePath(id: String) = TREE_PREFIX + id

    private fun parseTreePath(path: String): Pair<String, String> {
        val rest = path.removePrefix(TREE_PREFIX)
        val slash = rest.indexOf('/')
        return if (slash < 0) rest to "" else rest.substring(0, slash) to rest.substring(slash + 1)
    }

    private fun treeUriFor(id: String): Uri? {
        val stored = bookmarks().getString(keyFor(id), null) ?: return null
        return try {
            Uri.parse(stored)
        } catch (_: Exception) {
            null
        }
    }

    private fun bookmarkEntries(): List<Map<String, Any?>> {
        val prefs = bookmarks()
        return prefs.all.keys
            .filter { it.startsWith(BOOKMARK_PREFIX) }
            .mapNotNull { key ->
                val id = key.removePrefix(BOOKMARK_PREFIX)
                val uri = treeUriFor(id) ?: return@mapNotNull null
                val doc = DocumentFile.fromTreeUri(activity, uri) ?: return@mapNotNull null
                mapOf(
                    "name" to treeDisplayName(uri, doc),
                    "path" to treePath(id),
                    "isDirectory" to true,
                    "size" to 0L,
                    "bookmarkId" to id,
                )
            }
    }

    private fun treeDisplayName(treeUri: Uri, doc: DocumentFile?): String {
        doc?.name?.let { return it }
        val treeId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (_: Exception) {
            null
        }
        if (!treeId.isNullOrEmpty()) {
            val name = treeId.substringAfterLast(':')
            if (name.isNotEmpty()) return name
        }
        return treeUri.lastPathSegment ?: "Folder"
    }

    private fun removeBookmark(id: String) {
        val prefs = bookmarks()
        val stored = prefs.getString(keyFor(id), null)
        prefs.edit().remove(keyFor(id)).apply()
        if (stored != null) {
            try {
                activity.contentResolver.releasePersistableUriPermission(
                    Uri.parse(stored),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: Exception) {
            }
        }
    }

    // MARK: - Folder picker

    /// Launches the system folder picker (ACTION_OPEN_DOCUMENT_TREE). The result
    /// arrives in [MainActivity.onActivityResult] and is forwarded to
    /// [onFolderPicked].
    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("busy", "A folder picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        pendingFolderResult = result
        try {
            activity.startActivityForResult(intent, REQ_PICK_FOLDER)
        } catch (_: Exception) {
            pendingFolderResult = null
            result.error("no_picker", "No folder picker available", null)
        }
    }

    fun onFolderPicked(resultCode: Int, data: Intent?) {
        val result = pendingFolderResult ?: return
        pendingFolderResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null) // cancelled
            return
        }
        val treeUri = data.data!!
        try {
            activity.contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: Exception) {
        }
        val id = UUID.randomUUID().toString()
        bookmarks().edit().putString(keyFor(id), treeUri.toString()).apply()
        val doc = DocumentFile.fromTreeUri(activity, treeUri)
        result.success(
            mapOf(
                "name" to treeDisplayName(treeUri, doc),
                "path" to treePath(id),
                "isDirectory" to true,
                "size" to 0L,
                "bookmarkId" to id,
            ),
        )
    }
}
