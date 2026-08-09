package com.example.dream_player

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "dreamplayer/exo_player",
            ExoPlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        FileBrowser(this).configure(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FileBrowser.CHANNEL),
        )
    }
}
