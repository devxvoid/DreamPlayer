package com.dreamplayer.app

import android.content.Context
import android.os.Handler
import android.os.Looper
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
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.NextRenderersFactory
import java.io.File
import java.util.Locale

@UnstableApi
class ExoPlayerViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return ExoPlayerView(context, viewId, messenger)
    }
}

@UnstableApi
class ExoPlayerView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView {

    private val playerView = PlayerView(context).apply {
        useController = false
        resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
        setShutterBackgroundColor(android.graphics.Color.BLACK)
    }

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
    private val dataSourceFactory = DefaultDataSource.Factory(
        context,
        DefaultHttpDataSource.Factory(),
    )

    private val mediaSourceFactory = DefaultMediaSourceFactory(context)
        .setDataSourceFactory(dataSourceFactory)

    private val player: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(mediaSourceFactory)
        .setRenderersFactory(
            NextRenderersFactory(context)
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
            emit(error.errorCodeName)
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
                            if (!subtitleUri.isNullOrEmpty()) {
                                currentSubtitle = subtitleUri to subtitleLabel(subtitleUri)
                                setSubtitleConfigurations(
                                    listOf(
                                        MediaItem.SubtitleConfiguration.Builder(
                                            android.net.Uri.parse(subtitleUri),
                                        )
                                            .setMimeType(subtitleMimeType(subtitleUri))
                                            .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                                            .build(),
                                    ),
                                )
                            } else {
                                currentSubtitle = null
                            }
                        }
                        .build()
                    player.setMediaItem(mediaItem)
                    player.prepare()
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

    /// Turns the sideloaded subtitle track on/off. Media3 sideloaded subtitles
    /// surface as a text track group; off disables all text, on selects the
    /// first text group (v1 pairs a single subtitle per video).
    private fun setSubtitles(on: Boolean) {
        if (currentSubtitle == null) return
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

    /// `srt`/`sub`/`smi` -> subrip MIME (ExoPlayer's SRT parser handles it);
    /// `ass`/`ssa` -> SSA; `vtt` -> WebVTT.
    private fun subtitleMimeType(uri: String): String {
        val ext = uri.substringAfterLast('.').lowercase(Locale.ROOT)
        return when (ext) {
            "ass", "ssa" -> "text/x-ssa"
            "vtt" -> "text/vtt"
            else -> MimeTypes.APPLICATION_SUBRIP
        }
    }

    /// e.g. `Show.S01E01.eng.srt` -> `Show.S01E01.eng`.
    private fun subtitleLabel(uri: String): String =
        uri.substringAfterLast('/').substringBeforeLast('.').ifEmpty { uri }

    private fun emit(errorCodeName: String? = null) {
        val s = sink ?: return
        val videoFormat = player.videoFormat
        val audioFormat = player.audioFormat
        val videoSize = player.videoSize
        val state = player.playbackState

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
        map["colorTransfer"] = videoFormat?.colorInfo?.colorTransfer
        map["audioCodecs"] = audioFormat?.codecs
        map["audioMime"] = audioFormat?.sampleMimeType
        map["audioChannels"] = audioFormat?.channelCount
        val audioTracks = buildAudioTracks()
        map["audioTracks"] = audioTracks
        map["selectedAudioTrack"] =
            audioTracks.indexOfFirst { it["selected"] == true }
        map["subtitleLabel"] = currentSubtitle?.second
        map["subtitleOn"] = subtitleOn
        map["error"] = errorCodeName
        s.success(map)
    }

    override fun getView(): View = playerView

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
