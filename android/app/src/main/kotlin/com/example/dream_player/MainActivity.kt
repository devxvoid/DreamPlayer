package com.example.dream_player

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "dreamplayer/exo_player",
            ExoPlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
    }
}
