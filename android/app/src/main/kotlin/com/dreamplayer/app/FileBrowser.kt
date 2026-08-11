package com.dreamplayer.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/// In-app file browser (CX-Explorer style) backed by direct filesystem access.
/// Requires MANAGE_EXTERNAL_STORAGE on Android 11+.
class FileBrowser(private val activity: MainActivity) {

    companion object {
        const val CHANNEL = "dreamplayer/files"

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
        )
    }

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
        return roots
    }

    private fun rootEntry(path: String, name: String): Map<String, Any?> = mapOf(
        "name" to name,
        "path" to path,
        "isDirectory" to true,
        "size" to 0L,
    )

    private fun listDirectory(path: String): List<Map<String, Any?>> {
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
}
