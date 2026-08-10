package com.example.dream_player

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
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
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

    /// `smb://<serverId>/...` URIs stream through the SMB data source; every
    /// other scheme (file, content, http) falls through to the default sources.
    private val dataSourceFactory = DefaultDataSource.Factory(
        context,
        SmbDataSourceFactory(context),
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
        .build()
        .also { p ->
            p.repeatMode = Player.REPEAT_MODE_OFF
            p.volume = 1f
        }

    private val handler = Handler(Looper.getMainLooper())
    private var positionTicker: Runnable? = null

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
                    val mediaItem = when {
                        !uri.isNullOrEmpty() -> MediaItem.fromUri(android.net.Uri.parse(uri))
                        path != null -> MediaItem.fromUri(android.net.Uri.fromFile(File(path)))
                        else -> {
                            result.error("bad_args", "Missing path or uri", null)
                            return@setMethodCallHandler
                        }
                    }
                    player.setMediaItem(mediaItem)
                    player.prepare()
                    player.play()
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
}
