package com.dreamplayer.app

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.SurfaceControl
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.NextRenderersFactory
import okhttp3.OkHttpClient
import java.io.File
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

@UnstableApi
class ExoPlayerViewFactory(
    private val activity: Activity,
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return ExoPlayerView(activity, viewId, messenger)
    }
}

@UnstableApi
class ExoPlayerView(
    private val activity: Activity,
    viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView {

    private val playerView = ForcedAspectPlayerView(activity).apply {
        useController = false
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        setShutterBackgroundColor(android.graphics.Color.BLACK)
    }

    /// Last value handed to `Window.setDesiredHdrHeadroom`, to avoid re-setting
    /// the same ratio on every emit.
    private var hdrHeadroomSet = 1.0f

    /// Some devices allocate only 32 KiB input buffers for the MediaCodec FLAC
    /// decoder, which is too small for large FLAC frames (e.g. 24-bit
    /// multi-channel blocks ~54 KiB) and kills playback with
    /// `InsufficientCapacityException`. Route FLAC through the FFmpeg renderer,
    /// which sizes its buffers dynamically.
    ///
    /// On this OnePlus (OxygenOS), the codec2 resource manager repeatedly
    /// releases the Dolby hardware E-AC3 decoder (`c2.dolby.eac3.decoder`) as
    /// soon as it starts, so Media3's audio renderer spins in an endless
    /// re-init loop and no AudioTrack is ever created (silent playback). Skip
    /// the Dolby component for E-AC3/E-AC3-JOC so the AOSP decoder is used.
    private val mediaCodecSelector = MediaCodecSelector { mimeType, requiresSecureDecoder, requiresTunnelingDecoder ->
        when {
            mimeType == MimeTypes.AUDIO_FLAC -> emptyList()
            mimeType == MimeTypes.AUDIO_E_AC3 || mimeType == MimeTypes.AUDIO_E_AC3_JOC ->
                MediaCodecSelector.DEFAULT.getDecoderInfos(
                    mimeType,
                    requiresSecureDecoder,
                    requiresTunnelingDecoder,
                ).filterNot { it.name.contains("dolby", ignoreCase = true) }
            else -> MediaCodecSelector.DEFAULT.getDecoderInfos(
                mimeType,
                requiresSecureDecoder,
                requiresTunnelingDecoder,
            )
        }
    }

    /// Base source for non-file/content schemes. `DefaultDataSource` handles
    /// file/content/asset itself and delegates everything else (http, https,
    /// rtsp, ...) here — e.g. file managers that stream SMB files to players
    /// through a local HTTP proxy (CX Explorer hands out
    /// `http://127.0.0.1:<port>/SMB/...`, verified 4K HEVC at 60 fps).
    ///
    /// Playback uses OkHttp (not DefaultHttpDataSource, which wraps
    /// HttpURLConnection) so WebDAV servers with self-signed certificates can
    /// be played by swapping in a trust-all client per media item. HTTP
    /// headers (e.g. WebDAV Basic auth) are applied to the factory, not the
    /// MediaItem, in current Media3 — the player plays one item at a time, so
    /// setting default request properties at open time is correct.
    private val permissiveClient: OkHttpClient by lazy {
        val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, arrayOf(trustAll), SecureRandom())
        OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustAll)
            .hostnameVerifier { _, _ -> true }
            .build()
    }

    /// Uses the system trust store (the default) or [permissiveClient] based on
    /// [allowSelfSigned], which is flipped per media item at open time.
    private val httpDataSourceFactory = object : HttpDataSource.Factory {
        private val standard = OkHttpDataSource.Factory(OkHttpClient())
        private val permissive = OkHttpDataSource.Factory(permissiveClient)
        @Volatile var allowSelfSigned = false

        override fun createDataSource(): HttpDataSource =
            (if (allowSelfSigned) permissive else standard).createDataSource()

        override fun setDefaultRequestProperties(defaultRequestProperties: Map<String, String>): HttpDataSource.Factory {
            standard.setDefaultRequestProperties(defaultRequestProperties)
            permissive.setDefaultRequestProperties(defaultRequestProperties)
            return this
        }

        fun setPermissive(value: Boolean) {
            allowSelfSigned = value
        }
    }

    private val dataSourceFactory = DefaultDataSource.Factory(
        activity,
        httpDataSourceFactory,
    )

    private val subtitleParserFactory = DreamSubtitleParserFactory()

    private val mediaSourceFactory = DefaultMediaSourceFactory(
        dataSourceFactory,
        DefaultExtractorsFactory().setSubtitleParserFactory(subtitleParserFactory),
        subtitleParserFactory,
    )

    private val player: ExoPlayer = ExoPlayer.Builder(activity)
        .setMediaSourceFactory(mediaSourceFactory)
        .setRenderersFactory(
            NextRenderersFactory(activity)
                .apply {
                    setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
                    setEnableDecoderFallback(true)
                    setMediaCodecSelector(mediaCodecSelector)
                }
        )
        .setLoadControl(loadControl)
        .build()
        .also { p ->
            p.repeatMode = Player.REPEAT_MODE_OFF
            p.volume = 1f
        }

    private val handler = Handler(Looper.getMainLooper())
    private var positionTicker: Runnable? = null

    /// Auto-paired sideloaded subtitle: `(uri, display label)`.
    private var currentSubtitle: Pair<String, String>? = null
    private var subtitleOn = false

    private var sink: EventChannel.EventSink? = null

    private val methodChannel = MethodChannel(
        messenger,
        "dreamplayer/exo_$viewId",
    )

    private val eventChannel = EventChannel(
        messenger,
        "dreamplayer/exo_events_$viewId",
    )

    private val listener = object : Player.Listener {

        override fun onPlaybackStateChanged(playbackState: Int) {
            emit()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            updatePositionTicker()
            emit()
        }

        override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
            emit()
        }

        override fun onTracksChanged(tracks: androidx.media3.common.Tracks) {
            emit()
        }

        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo,
            newPosition: Player.PositionInfo,
            reason: Int,
        ) {
            emit()
        }

        override fun onPlayerError(error: PlaybackException) {
            emit(
                errorCodeName = error.errorCodeName,
                errorMessage = error.message,
                errorCause = error.cause?.message,
            )
        }
    }

    init {
        playerView.player = player
        player.addListener(listener)
        playerView.keepScreenOn = true

        methodChannel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "open" -> {
                    val path = call.argument<String>("path")
                    val uri = call.argument<String>("uri")
                    val subtitleUri = call.argument<String>("subtitleUri")
                    val startMs = call.argument<Number>("startPositionMs")?.toLong() ?: 0L
                    // HTTP request headers for this media item (e.g. WebDAV
                    // Basic auth). Media3 removed per-MediaItem headers; they
                    // now live on the HttpDataSource factory, which clearAndSet's
                    // them — so always call, clearing when empty.
                    val headers: Map<String, String> =
                        call.argument<Map<String, String>>("headers") ?: emptyMap()
                    httpDataSourceFactory.setDefaultRequestProperties(headers)
                    // Self-signed WebDAV servers: swap in the trust-all client.
                    httpDataSourceFactory.setPermissive(
                        call.argument<Boolean>("allowSelfSigned") ?: false,
                    )
                    val mediaItem = MediaItem.Builder()
                        .apply {
                            when {
                                !uri.isNullOrEmpty() -> setUri(android.net.Uri.parse(uri))
                                path != null -> setUri(android.net.Uri.fromFile(File(path)))
                                else -> {
                                    result.error("bad_args", "Missing path or uri", null)
                                    return@setMethodCallHandler
                                }
                            }
                        }
                        .apply {
                            // Auto-pair sibling subtitles next to the video
                            // (Just Player's `findSubtitle` rule, keeping every
                            // candidate so the picker can choose a language /
                            // format). An explicitly passed subtitle is still
                            // preferred over sibling pairing.
                            val paired: List<File> = if (subtitleUri.isNullOrEmpty() && path != null) {
                                SubtitleFormats.findSiblingSubtitles(path)
                            } else {
                                emptyList()
                            }
                            val candidates = if (subtitleUri.isNullOrEmpty()) {
                                paired
                            } else {
                                listOf(File(subtitleUri))
                            }
                            if (candidates.isNotEmpty()) {
                                currentSubtitle = candidates.first().absolutePath to
                                    SubtitleFormats.labelFromFileName(candidates.first().name)
                                setSubtitleConfigurations(
                                    candidates.mapIndexed { i, sub ->
                                        val originalUri = android.net.Uri.fromFile(sub)
                                        // Media3's parsers decode UTF-8 only;
                                        // re-encode CP1252/CP1251 etc. to UTF-8.
                                        val utf8Uri = SubtitleFormats.toUtf8(activity, originalUri)
                                        val name = sub.name
                                        val language = SubtitleFormats.languageFromFileName(name)
                                        MediaItem.SubtitleConfiguration.Builder(utf8Uri)
                                            .setMimeType(SubtitleFormats.mimeTypeFor(name))
                                            .setLanguage(language)
                                            .setRoleFlags(C.ROLE_FLAG_SUBTITLE)
                                            .setLabel(SubtitleFormats.labelFromFileName(name))
                                            // First (best) match is default-selected.
                                            .setSelectionFlags(
                                                if (i == 0) C.SELECTION_FLAG_DEFAULT else 0,
                                            )
                                            .build()
                                    },
                                )
                            } else {
                                currentSubtitle = null
                            }
                        }
                        .build()
                    player.setMediaItem(mediaItem)
                    player.prepare()
                    if (startMs > 0L) player.seekTo(startMs)
                    player.play()
                    subtitleOn = currentSubtitle != null
                    result.success(null)
                }
                "play" -> {
                    player.play()
                    result.success(null)
                }
                "pause" -> {
                    player.pause()
                    result.success(null)
                }
                "seekTo" -> {
                    val ms = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    player.seekTo(ms)
                    result.success(null)
                }
                "setVolume" -> {
                    val volume = call.argument<Number>("volume")?.toFloat() ?: 1f
                    player.volume = volume.coerceIn(0f, 1f)
                    result.success(null)
                }
                "setMuted" -> {
                    val muted = call.argument<Boolean>("muted") ?: false
                    player.volume = if (muted) 0f else 1f
                    result.success(null)
                }
                "getAudioTracks" -> {
                    result.success(buildAudioTracks())
                }
                // Pushes a fresh snapshot to the event stream and returns the
                // current state. Dart uses it after a background/foreground
                // cycle to detect whether the platform view was recreated
                // (player reset to IDLE) so it can reopen the media.
                "getState" -> {
                    emit()
                    result.success(stateMap())
                }
                "setAudioTrack" -> {
                    val index = call.argument<Number>("index")?.toInt() ?: -1
                    selectAudioTrack(index)
                    result.success(null)
                }
                "setSubtitles" -> {
                    val on = call.argument<Boolean>("on") ?: true
                    setSubtitles(on)
                    result.success(null)
                }
                "getSubtitleTracks" -> {
                    result.success(buildSubtitleTracks())
                }
                "setSubtitleTrack" -> {
                    val index = call.argument<Number>("index")?.toInt() ?: -1
                    selectSubtitleTrack(index)
                    result.success(null)
                }
                "setResizeMode" -> {
                    applyFitMode(call.argument<Number>("mode")?.toInt() ?: 0)
                    result.success(null)
                }
                "dispose" -> {
                    stopPositionTicker()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                emit()
                updatePositionTicker()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
                stopPositionTicker()
            }
        })
    }

    private fun updatePositionTicker() {
        if (sink == null) return
        if (player.isPlaying && positionTicker == null) {
            positionTicker = object : Runnable {
                override fun run() {
                    emit()
                    if (player.isPlaying) {
                        handler.postDelayed(this, 250)
                    }
                }
            }
            handler.postDelayed(positionTicker!!, 250)
        } else if (!player.isPlaying) {
            stopPositionTicker()
        }
    }

    private fun stopPositionTicker() {
        positionTicker?.let { handler.removeCallbacks(it) }
        positionTicker = null
    }

    /// Flat list of the current audio tracks (one entry per format), for the
    /// audio-track picker. `index` is the flat index used by `setAudioTrack`.
    private fun buildAudioTracks(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        var flat = 0
        val playingAudio = player.audioFormat
        for (group in player.currentTracks.groups) {
            if (group.type != C.TRACK_TYPE_AUDIO || !group.isSupported) continue
            val trackGroup = group.mediaTrackGroup
            for (i in 0 until trackGroup.length) {
                val f = trackGroup.getFormat(i)
                val map = HashMap<String, Any?>()
                map["index"] = flat
                map["language"] = f.language
                map["codecs"] = f.codecs
                map["mime"] = f.sampleMimeType
                map["channels"] = f.channelCount
                map["bitrate"] = f.bitrate
                map["label"] = f.label
                map["selected"] = group.isSelected &&
                    (trackGroup.length == 1 || playingAudio === f)
                out.add(map)
                flat++
            }
        }
        return out
    }

    private fun selectAudioTrack(flatIndex: Int) {
        var flat = 0
        var override: TrackSelectionOverride? = null
        for (group in player.currentTracks.groups) {
            if (group.type != C.TRACK_TYPE_AUDIO || !group.isSupported) continue
            val trackGroup = group.mediaTrackGroup
            for (i in 0 until trackGroup.length) {
                if (flat == flatIndex) {
                    override = TrackSelectionOverride(trackGroup, i)
                }
                flat++
            }
        }
        if (override == null) return
        val params = player.trackSelectionParameters
            .buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
            .setOverrideForType(override)
            .build()
        player.setTrackSelectionParameters(params)
    }

    /// Turns text (subtitle) rendering on/off. Works for both embedded
    /// container tracks (PGS/DVB/CEA/SRT in MKV/MP4) and sideloaded sidecar
    /// subtitles — Media3 surfaces both as text track groups.
    private fun setSubtitles(on: Boolean) {
        subtitleOn = on
        val builder = player.trackSelectionParameters.buildUpon()
        if (on) {
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            val textGroup = player.currentTracks.groups
                .firstOrNull { it.type == C.TRACK_TYPE_TEXT && it.isSupported }
            if (textGroup != null) {
                builder
                    .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                    .setOverrideForType(TrackSelectionOverride(textGroup.mediaTrackGroup, 0))
            }
        } else {
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        }
        player.setTrackSelectionParameters(builder.build())
    }

    /// Flat list of the current subtitle tracks (embedded + sideloaded), one
    /// entry per format, for the subtitle picker. `index` is the flat index
    /// used by [selectSubtitleTrack].
    private fun buildSubtitleTracks(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        var flat = 0
        for (group in player.currentTracks.groups) {
            if (group.type != C.TRACK_TYPE_TEXT || !group.isSupported) continue
            val trackGroup = group.mediaTrackGroup
            for (i in 0 until trackGroup.length) {
                val f = trackGroup.getFormat(i)
                val map = HashMap<String, Any?>()
                map["index"] = flat
                map["language"] = f.language
                map["label"] = f.label
                map["codecs"] = f.codecs
                map["mime"] = f.sampleMimeType
                map["sideloaded"] = MimeTypes.APPLICATION_MEDIA3_CUES == f.sampleMimeType
                map["selected"] = group.isSelected
                out.add(map)
                flat++
            }
        }
        return out
    }

    /// Selects the subtitle track at [flatIndex]; -1 turns subtitles off.
    private fun selectSubtitleTrack(flatIndex: Int) {
        val builder = player.trackSelectionParameters.buildUpon()
        if (flatIndex < 0) {
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            subtitleOn = false
            player.setTrackSelectionParameters(builder.build())
            return
        }
        var flat = 0
        var override: TrackSelectionOverride? = null
        for (group in player.currentTracks.groups) {
            if (group.type != C.TRACK_TYPE_TEXT || !group.isSupported) continue
            val trackGroup = group.mediaTrackGroup
            for (i in 0 until trackGroup.length) {
                if (flat == flatIndex) {
                    override = TrackSelectionOverride(trackGroup, i)
                }
                flat++
            }
        }
        if (override == null) return
        builder
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .setOverrideForType(override)
        subtitleOn = true
        player.setTrackSelectionParameters(builder.build())
    }

    /// Display name of the sideloaded subtitle format, for the chip / sheet.
    private fun subtitleFormat(uri: String): String {
        return when (SubtitleFormats.mimeTypeFor(uri)) {
            MimeTypes.TEXT_SSA -> "SSA/ASS"
            MimeTypes.TEXT_VTT -> "WebVTT"
            MimeTypes.APPLICATION_TTML -> "TTML"
            SubtitleFormats.MIME_SAMI -> "SAMI"
            SubtitleFormats.MIME_MICRODVD -> "MicroDVD"
            SubtitleFormats.MIME_MPL2 -> "MPL2"
            else -> "SRT"
        }
    }

    /// Requests HDR headroom from the display pipeline (Android 13+). On
    /// OnePlus/OxygenOS the display's HDR mode only engages when the WINDOW
    /// asks for headroom: with the default the panel keeps the SDR UI undimmed
    /// and squeezes PQ highlights, so bright HDR skies clip flat to white.
    /// `Window.setDesiredHdrHeadroom` puts the request on the activity's window
    /// layer — Nova does exactly this (its dump shows `desired hdr/sdr
    /// ratio=5.0` on the PlayerActivity window layer with the SDR UI dimmed to
    /// ~0.68, while the SurfaceView API puts the ratio on the video layer where
    /// OPLUS ignores it for the EDR ramp; verified on-device with the HDR10+
    /// "lake" test clip).
    ///
    /// The window must ALSO be switched to `COLOR_MODE_HDR`. Nova calls
    /// `window.setColorMode(COLOR_MODE_HDR)` the moment HDR capabilities are
    /// detected, and OPLUS gates the headroom/EDR ramp on the window layer
    /// actually being in HDR color mode — Nova's window layer is DISPLAY_P3
    /// (0x188a0000) with the ratio; ours stayed at the default V0_SRGB until
    /// this was added, which is why the headroom call alone had no visible
    /// effect on the "lake" clip.
    ///
    /// Finally the video surface's dataspace is set CONSUMER-side via
    /// `SurfaceControl.Transaction.setDataSpace` (Nova's `setSurfaceDataSpace`).
    /// Without it, OPLUS HWC reports `UNSUPPORTDATASPACE` for the BT2020_PQ
    /// layer and SF falls back to client composition, which never engages the
    /// EDR boost — the `current hdr/sdr ratio` stays 1.0 (verified in dumpsys:
    /// Nova's video layer is device-composited with the ratio ramping at 1.468;
    /// ours was `forceClientComposition=true clientType=UNSUPPORTDATASPACE` and
    /// stuck at 1.0 until this call).
    private fun applyHdrHeadroom(desired: Float, colorTransfer: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val window = activity.window ?: return
        val mode =
            if (desired > 1.0f) ActivityInfo.COLOR_MODE_HDR else ActivityInfo.COLOR_MODE_DEFAULT
        if (window.colorMode != mode) {
            window.colorMode = mode
            android.util.Log.d("DreamPlayerHDR", "setColorMode($mode)")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && desired != hdrHeadroomSet) {
            window.setDesiredHdrHeadroom(desired)
            android.util.Log.d("DreamPlayerHDR", "setDesiredHdrHeadroom($desired)")
            hdrHeadroomSet = desired
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val sv = playerView.videoSurfaceView as? android.view.SurfaceView
            val sc = sv?.surfaceControl
            if (sc != null && sc.isValid) {
                val dataSpace =
                    when {
                        desired > 1.0f && colorTransfer == C.COLOR_TRANSFER_HLG ->
                            0x12060000 // HAL_DATASPACE_BT2020_HLG
                        desired > 1.0f -> 0x10C00000 // HAL_DATASPACE_BT2020_PQ
                        else -> 0
                    }
                SurfaceControl.Transaction().setDataSpace(sc, dataSpace).apply()
                android.util.Log.d(
                    "DreamPlayerHDR",
                    "setSurfaceDataSpace(0x${Integer.toHexString(dataSpace)})",
                )
            }
        }
    }

    private fun stateMap(
        errorCodeName: String? = null,
        errorMessage: String? = null,
        errorCause: String? = null,
    ): Map<String, Any?> {
        val videoFormat = player.videoFormat
        val audioFormat = player.audioFormat
        val videoSize = player.videoSize
        val state = player.playbackState

        // Engage the display's HDR tone map (see [applyHdrHeadroom]) whenever
        // the current video is HDR (PQ or HLG transfer — includes the DV base
        // layer); fall back to 1.0 (no boost) for SDR content.
        val colorTransfer = videoFormat?.colorInfo?.colorTransfer
        applyHdrHeadroom(
            when (colorTransfer) {
                C.COLOR_TRANSFER_ST2084, C.COLOR_TRANSFER_HLG -> 5.0f
                else -> 1.0f
            },
            colorTransfer ?: -1,
        )

        val map = HashMap<String, Any?>()
        map["state"] = state
        map["playing"] = player.isPlaying
        map["positionMs"] = player.currentPosition
        map["durationMs"] = if (player.duration == C.TIME_UNSET) 0L else player.duration
        map["buffering"] = state == Player.STATE_BUFFERING
        map["ended"] = state == Player.STATE_ENDED
        map["videoCodecs"] = videoFormat?.codecs
        map["videoMime"] = videoFormat?.sampleMimeType
        map["videoWidth"] = videoSize.width
        map["videoHeight"] = videoSize.height
        map["colorTransfer"] = colorTransfer
        map["audioCodecs"] = audioFormat?.codecs
        map["audioMime"] = audioFormat?.sampleMimeType
        map["audioChannels"] = audioFormat?.channelCount
        val audioTracks = buildAudioTracks()
        map["audioTracks"] = audioTracks
        map["selectedAudioTrack"] =
            audioTracks.indexOfFirst { it["selected"] == true }
        map["subtitleLabel"] = currentSubtitle?.second
        map["subtitleFormat"] = currentSubtitle?.let { subtitleFormat(it.first) }
        val subtitleTracks = buildSubtitleTracks()
        val selectedSubtitle = subtitleTracks.indexOfFirst { it["selected"] == true }
        // Keep the manual toggle and the real selection in sync: the CC button
        // reflects whether a text track is actually selected.
        subtitleOn = selectedSubtitle >= 0
        map["subtitleOn"] = subtitleOn
        map["subtitleTracks"] = subtitleTracks
        map["selectedSubtitleTrack"] = selectedSubtitle
        map["error"] = errorCodeName
        map["errorMessage"] = errorMessage
        map["errorCause"] = errorCause
        return map
    }

    private fun emit(
        errorCodeName: String? = null,
        errorMessage: String? = null,
        errorCause: String? = null,
    ) {
        sink?.success(stateMap(errorCodeName, errorMessage, errorCause))
    }

    override fun getView(): View = playerView

    /// Applies the Dart-side [VideoFitMode] to the surface. Fixed ratios
    /// (16:9 / 4:3) force the content frame's aspect ratio and zoom-crop into
    /// it; the others map 1:1 to Media3 resize modes.
    private fun applyFitMode(mode: Int) {
        when (mode) {
            1 -> { // Crop to screen (keeps aspect, fills view)
                playerView.forcedAspect = null
                playerView.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
            }
            2 -> { // Stretch to screen (distorts)
                playerView.forcedAspect = null
                playerView.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FILL
            }
            3 -> { // 16:9 crop
                playerView.forcedAspect = 16f / 9f
                playerView.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
            }
            4 -> { // 4:3 crop
                playerView.forcedAspect = 4f / 3f
                playerView.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
            }
            else -> { // Fit (letterbox)
                playerView.forcedAspect = null
                playerView.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            }
        }
        playerView.applyForced()
    }

    override fun dispose() {
        stopPositionTicker()
        player.removeListener(listener)
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        player.release()
        playerView.player = null
    }

    companion object {
        /// Start playback almost immediately (2s of media buffered is enough),
        /// resume quickly after a stall (5s), but keep topping the buffer up to
        /// a big byte budget so network streams (e.g. the CX HTTP proxy) stay
        /// smooth. Defaults are 2.5s/5s and an 8MB byte cap, which is too tight
        /// for 4K REMUX.
        private val loadControl: LoadControl =
            DefaultLoadControl.Builder()
                .setBufferDurationsMs(60_000, 120_000, BUFFER_FOR_PLAYBACK_MS, BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
                .setTargetBufferBytes(TARGET_BUFFER_BYTES)
                .build()

        private const val BUFFER_FOR_PLAYBACK_MS = 2_000
        private const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 5_000
        private const val TARGET_BUFFER_BYTES = 96 * 1024 * 1024
    }
}

/// `PlayerView` whose content frame can be pinned to a fixed aspect ratio
/// (16:9 / 4:3). Media3 doesn't expose an aspect override on `PlayerView`, but
/// `onContentAspectRatioChanged` hands us the internal `AspectRatioFrameLayout`
/// on every video-size change, so we can force its ratio after the fact.
@UnstableApi
private class ForcedAspectPlayerView(context: Context) : PlayerView(context) {

    /// When non-null, the content frame is forced to this ratio (and the caller
    /// typically pairs it with `RESIZE_MODE_ZOOM` so overflow is cropped).
    var forcedAspect: Float? = null

    private var contentFrame: AspectRatioFrameLayout? = null
    private var contentAspect: Float = 1f

    override fun onContentAspectRatioChanged(
        contentFrame: AspectRatioFrameLayout?,
        contentAspectRatio: Float,
    ) {
        super.onContentAspectRatioChanged(contentFrame, contentAspectRatio)
        this.contentFrame = contentFrame
        this.contentAspect = contentAspectRatio
        applyForced()
    }

    /// Re-applies the forced ratio (or restores the natural one) immediately,
    /// so switching modes mid-playback relayouts the frame without waiting for
    /// the next video-size change.
    fun applyForced() {
        val frame = contentFrame ?: return
        frame.setAspectRatio(forcedAspect ?: contentAspect)
    }
}
