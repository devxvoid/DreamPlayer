package com.dreamplayer.app

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var intentChannel: MethodChannel? = null
    private var fileBrowser: FileBrowser? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "dreamplayer/exo_player",
            ExoPlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        fileBrowser = FileBrowser(this)
        fileBrowser!!.configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FileBrowser.CHANNEL),
        )
        WebDAVClient(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WebDAVClient.CHANNEL),
        )
        MulticastLockManager(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dreamplayer/multicast"),
        )
        intentChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dreamplayer/intent",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialIntent" -> {
                        result.success(intentPayload(intent))
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intentChannel?.invokeMethod("open", intentPayload(intent))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FileBrowser.REQ_PICK_FOLDER) {
            fileBrowser?.onFolderPicked(resultCode, data)
        }
    }

    /// Maps a VIEW intent to {uri, title, path?}. Returns null for non-VIDEO
    /// launches (launcher icon etc.).
    private fun intentPayload(intent: Intent?): Map<String, Any?>? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        val payload = HashMap<String, Any?>()
        when (data.scheme) {
            "file" -> {
                payload["uri"] = data.toString()
                payload["path"] = data.path
                payload["title"] = data.lastPathSegment
            }
            "content" -> {
                payload["uri"] = data.toString()
                payload["title"] = queryDisplayName(data) ?: data.lastPathSegment
                val realPath = queryPath(data)
                if (realPath != null) payload["path"] = realPath
            }
            else -> {
                payload["uri"] = data.toString()
                payload["title"] = data.lastPathSegment
            }
        }
        return payload
    }

    private fun queryDisplayName(uri: Uri): String? =
        queryString(uri, OpenableColumns.DISPLAY_NAME)

    /// The `_data` column is deprecated but still the only way to get a real
    /// file path for a content URI.
    private fun queryPath(uri: Uri): String? =
        queryString(uri, "_data")

    private fun queryString(uri: Uri, column: String): String? = try {
        contentResolver.query(uri, arrayOf(column), null, null, null)?.use { c ->
            val index = c.getColumnIndex(column)
            if (index >= 0 && c.moveToFirst()) c.getString(index) else null
        }
    } catch (_: Exception) {
        null
    }
}
