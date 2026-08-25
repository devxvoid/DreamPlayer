package com.dreamplayer.app

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.graphics.Color
import android.media.audiofx.LoudnessEnhancer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
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
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import com.dreamplayer.app.DreamRenderersFactory
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
        setKeepContentOnPlayerReset(true)
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
    ///
    /// **Audio passthrough (TV / eARC)**: when the user enables "Audio
    /// passthrough" in Settings AND an HDMI output is detected, we return an
    /// empty decoder list for all passthrough-capable formats (AC3, E-AC3,
    /// DTS, DTS-HD, TrueHD).  This forces ExoPlayer's `DefaultAudioSink` to
    /// route them through `AudioTrack` in passthrough mode — the encoded
    /// bitstream goes straight to the HDMI output for the TV / soundbar / AVR
    /// to decode.  The FfmpegAudioRenderer (appended last in
    /// DreamRenderersFactory) never fires for these formats because
    /// `MediaCodecAudioRenderer` claims them first via `audioSink.supportsFormat`.
    /// FLAC still falls through to FFmpeg (no FLAC passthrough exists).
    private val passthroughEnabled: Boolean =
        PlayerCodecs.passthroughEnabled(activity)

    private val mediaCodecSelector: MediaCodecSelector =
        PlayerCodecs.mediaCodecSelector(activity)

    // ---- Volume Boost + Night Mode (LoudnessEnhancer on AudioTrack session) ----
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var audioBoost: Float = run {
        val p = activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = p.all["flutter.dreamplayer.audioBoost"]
        when (raw) {
            is Float -> raw
            is Double -> raw.toFloat()
            is Number -> raw.toFloat()
            is String -> raw.toFloatOrNull() ?: 1.0f
            else -> 1.0f
        }.coerceIn(1.0f, 3.0f)
    }
    private var nightModeEnabled: Boolean = run {
        val p = activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        p.getBoolean("flutter.dreamplayer.nightMode", false)
    }

    // ---- Bass Boost (android.media.audiofx.BassBoost on the session) ----
    // Exists to offset the low-end thinning that HRTF spatialization causes.
    // 0 = off, 1 = Low, 2 = Medium, 3 = High (strength 0–1000).
    private var bassBoostLevel: Int = run {
        val p = activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        p.getInt("flutter.dreamplayer.bassBoost", 0).coerceIn(0, 3)
    }
    private var bassBoostFx: android.media.audiofx.BassBoost? = null

    // ---- Spatial audio (Android 13+ platform Spatializer) ----
    //
    // The effect lives at the AudioFlinger level: when the user enables
    // "Spatial audio" for their output device, multichannel PCM we decode
    // (DTS-HD / E-AC3 / TrueHD -> 5.1/7.1 into AudioTrack) is virtualized to
    // stereo automatically - Media3 routes through it with zero app code,
    // and it cannot be force-enabled from an app. Everything here is gated
    // to API 33+; on older devices (minSdk 21) this is a silent no-op and
    // no chip is shown. We only DETECT and report so the player top bar can
    // show a chip while it is engaged:
    //   on          - enabled + available for current routing + the track's
    //                 channel layout would actually be spatialized.
    //   available   - routing supports it, but the user toggle is off (or
    //                 the track is plain stereo, which stays flat).
    //   unavailable - no platform spatializer / API < 33 / probe failed.

    /// Whether the platform would virtualize a PCM stream with [channels]
    /// channels at [sampleRate] under media/movie attributes.
    private fun wouldBeSpatialized(channels: Int, sampleRate: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val mask = when {
            channels >= 8 -> android.media.AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
            channels >= 6 -> android.media.AudioFormat.CHANNEL_OUT_5POINT1
            channels == 1 -> android.media.AudioFormat.CHANNEL_OUT_MONO
            else -> android.media.AudioFormat.CHANNEL_OUT_STEREO
        }
        return try {
            val fmt = android.media.AudioFormat.Builder()
                .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(if (sampleRate > 0) sampleRate else 48_000)
                .setChannelMask(mask)
                .build()
            val attrs = android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            activity.getSystemService(android.media.AudioManager::class.java)
                .spatializer.canBeSpatialized(attrs, fmt)
        } catch (_: Exception) {
            false
        }
    }

    private fun spatialStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "unavailable"
        return try {
            val sp = activity
                .getSystemService(android.media.AudioManager::class.java)
                .spatializer
            val fmt = player.audioFormat
            val channels = fmt?.channelCount ?: 0
            when {
                !sp.isAvailable || !sp.isEnabled || channels <= 2 -> "available"
                wouldBeSpatialized(channels, fmt?.sampleRate ?: 0) -> "on"
                else -> "available"
            }
        } catch (_: Exception) {
            "unavailable"
        }
    }

    /// Re-emits state when the system toggle flips or routing changes
    /// (headphones plugged / unplugged) while playing. Note the callback
    /// signatures take the Spatializer as first arg (public API differs
    /// from the hidden SystemApi docs floating around).
    private val spatialExecutor = java.util.concurrent.Executor { it.run() }
    private val spatialListener: android.media.Spatializer.OnSpatializerStateChangedListener? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            object : android.media.Spatializer.OnSpatializerStateChangedListener {
                override fun onSpatializerEnabledChanged(
                    sp: android.media.Spatializer,
                    enabled: Boolean,
                ) {
                    handler.post { emit() }
                }

                override fun onSpatializerAvailableChanged(
                    sp: android.media.Spatializer,
                    available: Boolean,
                ) {
                    handler.post { emit() }
                }
            }
        } else {
            null
        }
    private var spatialRegistered = false

    private fun registerSpatialListenerOnce() {
        if (spatialRegistered) return
        spatialRegistered = true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        try {
            val sp = activity
                .getSystemService(android.media.AudioManager::class.java)
                .spatializer
            spatialListener?.let { sp.addOnSpatializerStateChangedListener(spatialExecutor, it) }
        } catch (_: Exception) {}
    }

    private fun unregisterSpatialListener() {
        if (!spatialRegistered) return
        spatialRegistered = false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        try {
            val sp = activity
                .getSystemService(android.media.AudioManager::class.java)
                .spatializer
            spatialListener?.let { sp.removeOnSpatializerStateChangedListener(it) }
        } catch (_: Exception) {}
    }

    private fun applyAudioEffects() {
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        loudnessEnhancer = null
        try { bassBoostFx?.release() } catch (_: Exception) {}
        bassBoostFx = null
        val sessionId = player.audioSessionId
        val sessionOk = sessionId != 0 && sessionId != C.AUDIO_SESSION_ID_UNSET
        // Bass Boost is independent of the loudness guard — it applies even
        // at 1.0× boost / night mode off.
        if (sessionOk && bassBoostLevel > 0) {
            try {
                val bb = android.media.audiofx.BassBoost(0, sessionId)
                bb.setStrength(((bassBoostLevel * 333).coerceAtMost(1000)).coerceAtLeast(150).toShort())
                bb.enabled = true
                bassBoostFx = bb
            } catch (e: Exception) {
                Log.w("ExoPlayerView", "BassBoost failed", e)
            }
        }
        if (audioBoost <= 1.0f && !nightModeEnabled) return
        if (!sessionOk) return
        try {
            val enhancer = LoudnessEnhancer(sessionId)
            val gainMb = when {
                nightModeEnabled && audioBoost <= 1.0f -> 400
                nightModeEnabled -> (((audioBoost - 1f) * 750).toInt() + 300).coerceIn(0, 1500)
                else -> (((audioBoost - 1f) * 750).toInt()).coerceIn(0, 1500)
            }
            enhancer.setTargetGain(gainMb)
            enhancer.enabled = true
            loudnessEnhancer = enhancer
        } catch (e: Exception) {
            Log.w("ExoPlayerView", "LoudnessEnhancer failed", e)
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

    /// Routes URIs to the correct data source based on scheme:
    ///  - smb:// → SmbDataSource (jcifs-ng streaming with ring buffer)
    ///  - everything else → DefaultDataSource (local + OkHttp for http/https)
    private val dataSourceFactory = object : DataSource.Factory {
        private val local = DefaultDataSource.Factory(activity, httpDataSourceFactory)

        override fun createDataSource(): DataSource = MultiplexDataSource(local, activity)
    }

    /// A [DataSource] that inspects the URI scheme on [open] and delegates to
    /// [SmbDataSource] for `smb://`, [FtpDataSource] for `ftp://`/`sftp://`,
    /// or to [local] for everything else.
    private class MultiplexDataSource(
        private val local: DefaultDataSource.Factory,
        private val context: Context,
    ) : BaseDataSource(/* isNetwork= */ true) {
        private var delegate: DataSource? = null

        override fun open(dataSpec: DataSpec): Long {
            delegate = when (dataSpec.uri.scheme?.lowercase()) {
                "smb" -> SmbDataSource(context)
                "ftp", "sftp" -> FtpDataSource(context)
                else -> local.createDataSource()
            }
            return delegate!!.open(dataSpec)
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            delegate!!.read(buffer, offset, length)

        override fun getUri(): Uri? = delegate?.uri

        override fun close() {
            delegate?.close()
            delegate = null
        }
    }

    private val subtitleParserFactory = DreamSubtitleParserFactory()

    private val mediaSourceFactory = DefaultMediaSourceFactory(
        dataSourceFactory,
        DefaultExtractorsFactory().setSubtitleParserFactory(subtitleParserFactory),
        subtitleParserFactory,
    )

    /// Start playback almost immediately (2s of media buffered is enough),
    /// resume quickly after a stall (5s), but keep topping the buffer up to
    /// a big byte budget so network streams (e.g. the CX HTTP proxy) stay
    /// smooth. Defaults are 2.5s/5s and an 8MB byte cap, which is too tight
    /// for 4K REMUX. The byte budget scales down on small-heap devices
    /// ([BufferTuning]) — a fixed 96MB target OOMs the Fire TV Stick's 192MB
    /// app heap mid-playback ("io unspecified" source error).
    private val loadControl: LoadControl = run {
        BufferTuning.tune(activity)
        DefaultLoadControl.Builder()
            .setBufferDurationsMs(15_000, 50_000, BUFFER_FOR_PLAYBACK_MS, BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
            .setTargetBufferBytes(BufferTuning.media3TargetBytes)
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
    }

    private val player: ExoPlayer = ExoPlayer.Builder(activity)
        .setMediaSourceFactory(mediaSourceFactory)
        .setRenderersFactory(
            DreamRenderersFactory(activity)
                .apply {
                    setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
                    setEnableDecoderFallback(true)
                    setAllowedVideoJoiningTimeMs(0L)
                    setMediaCodecSelector(mediaCodecSelector)
                }
        )
        .setLoadControl(loadControl)
        .build()
        .also { p ->
            p.repeatMode = Player.REPEAT_MODE_OFF
            p.volume = 1f
            // No language preference: Media3's empty preferredAudioLanguages
            // already selects the container's DEFAULT-flagged audio track
            // (first track as last resort) — exactly the file's own default.
            p.addAnalyticsListener(object : AnalyticsListener {
                override fun onVideoDecoderInitialized(
                    eventTime: AnalyticsListener.EventTime,
                    decoderName: String,
                    initializedTimestampMs: Long,
                    initializationDurationMs: Long,
                ) {
                    currentVideoDecoderName = decoderName
                    handler.post { emit() }
                }
                override fun onVideoDecoderReleased(
                    eventTime: AnalyticsListener.EventTime,
                    decoderName: String,
                ) {
                    // Keep last name until next init so the badge doesn't flicker.
                }
            })
        }

    private val handler = Handler(Looper.getMainLooper())
    private var positionTicker: Runnable? = null

    /// Display mode captured when the platform view attaches; restored on
    /// dispose so leaving playback returns the panel to the startup-selected
    /// rate (flutter_displaymode's high-refresh pick).
    private var initialModeId: Int? = null

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
            if (playbackState == Player.STATE_READY) matchRefreshRate()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            updatePositionTicker()
            emit()
        }

        override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
            emit()
            matchRefreshRate()
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

        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            handler.post { applyAudioEffects(); emit() }
        }
    }

    /// Whether this device ships a `video/dolby-vision` decoder (checked once —
    /// DV-capable hardware like the OnePlus's `c2.qti.dv.decoder`; absent on
    /// e.g. the Redmi Note 10).
    private val hasDvDecoder: Boolean by lazy {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.contains(MimeTypes.VIDEO_DOLBY_VISION)
        }
    }

    /// Media3 reports DV tracks as `dvhe.<profile>.<level>` (mp4 sample entry
    /// + DOVI config), e.g. `dvhe.05.09` for Profile 5 Level 9.
    private fun isDvProfile5(codecs: String?): Boolean =
        codecs?.let { Regex("dv(?:he|h1|av)\\.05\\.").containsMatchIn(it) } == true

    /// Set once when a P5 stream is rejected on a DV-less device; reset on
    /// open() so a subsequent non-P5 file plays normally.
    private var dvRejectionShown = false

    /// Dolby Vision Profile 5 (IPTPQc2 color) cannot be rendered by a plain
    /// HEVC decoder: on devices without a `video/dolby-vision` codec it comes
    /// out pink/green (see [mediaCodecSelector] — P7/P8 base layers ARE HDR10
    /// HEVC and fall back correctly; P5 is not). Detect it as soon as the video
    /// format is known and fail with a clear message instead of garbage frames.
    /// Returns the error fields to surface, or null to keep normal playback.
    private fun dvP5Rejection(): Pair<String, String>? {
        if (hasDvDecoder || dvRejectionShown) return null
        if (!isDvProfile5(player.videoFormat?.codecs)) return null
        dvRejectionShown = true
        player.stop()
        return "UnsupportedDolbyVisionProfile5" to
            ("This device cannot decode Dolby Vision Profile 5. Play the HDR10 or " +
                "SDR version of this video, or use a device with Dolby Vision support.")
    }

    /// Whether the current video carries ST 2094-40 (HDR10+) dynamic metadata,
    /// found by probing the bitstream — Media3's format info cannot tell HDR10+
    /// from HDR10 (both are PQ transfer). Best-effort: a probe failure just
    /// leaves this false and the content plays with the plain HDR10 label.
    @Volatile private var hdr10PlusContent = false

    /// Whether the current video carries static HDR10 metadata (SEI payload types
    /// 137 = mastering display colour volume, 144 = content light level). This
    /// covers plain HDR10 files that omit the MKV Colour element — Media3's
    /// MatroskaExtractor doesn't populate `Format.colorInfo`, so the app would
    /// fall back to SDR. Probing the bitstream SEI restores the correct HDR10 label
    /// and engages the OPLUS EDR headroom path.
    @Volatile private var hdr10Content = false

    /// MKV chapters parsed from the local container on open (Media3 has no
    /// chapters API). Empty for network sources or files without chapters.
    @Volatile private var chapters: List<MkvChapters.Chapter> = emptyList()

    /// Name of the video decoder currently in use (e.g. `c2.qti.hevc.decoder`
    /// for HW, `c2.android.hevc.decoder` for SW). Updated via
    /// `AnalyticsListener.onVideoDecoderInitialized`.
    @Volatile private var currentVideoDecoderName: String? = null

    /// Scans the first video samples for an HDR10+ SEI (ITU-T T.35 user data,
    /// country 0xB5 / provider 0x003C = ST 2094-40) on a background thread and
    /// flips [hdr10PlusContent], re-emitting the event map so the UI upgrades
    /// the label from HDR10 to HDR10+. Never blocks playback or the main thread.
    private fun probeHdr10Plus(path: String?, uri: String?, headers: Map<String, String>) {
        Thread {
            try {
                if (scanForHdr10Plus(path, uri, headers) && !hdr10PlusContent) {
                    hdr10PlusContent = true
                    handler.post { emit() }
                }
            } catch (_: Throwable) {
                // Best-effort probe; never let it affect playback.
            }
        }.apply { isDaemon = true }.start()
    }

    private fun scanForHdr10Plus(
        path: String?,
        uri: String?,
        headers: Map<String, String>,
    ): Boolean {
        val extractor = MediaExtractor()
        try {
            when {
                path != null -> extractor.setDataSource(path)
                uri != null -> {
                    val u = android.net.Uri.parse(uri)
                    when (u.scheme) {
                        "file" -> u.path?.let { extractor.setDataSource(it) } ?: return false
                        "content" -> extractor.setDataSource(activity, u, null)
                        else -> extractor.setDataSource(activity, u, headers.ifEmpty { null })
                    }
                }
                else -> return false
            }
            var videoTrack = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("video/") == true) {
                    videoTrack = i
                    break
                }
            }
            if (videoTrack < 0) return false
            extractor.selectTrack(videoTrack)
            val buffer = ByteArray(512 * 1024)
            var samples = 0
            while (samples < 256) {
                val size = extractor.readSampleData(java.nio.ByteBuffer.wrap(buffer), 0)
                if (size <= 0) break
                if (sampleHasHdr10PlusSei(buffer, size)) return true
                samples++
                val timeUs = extractor.sampleTime
                if (timeUs > 0 && timeUs > 4_000_000L) break
                extractor.advance()
            }
            return false
        } catch (_: Exception) {
            return false
        } finally {
            extractor.release()
        }
    }

    /// Scans one encoded video sample for the HDR10+ SEI. Samples are usually
    /// AVCC length-prefixed NAL units; Annex-B (00 00 01 start codes, e.g. TS)
    /// is handled too.
    private fun sampleHasHdr10PlusSei(buf: ByteArray, size: Int): Boolean {
        val annexB = (size >= 4 && buf[0] == 0.toByte() && buf[1] == 0.toByte() &&
            buf[2] == 1.toByte()) ||
            (size >= 5 && buf[0] == 0.toByte() && buf[1] == 0.toByte() &&
                buf[2] == 0.toByte() && buf[3] == 1.toByte())
        if (annexB) {
            var i = nextStartCode(buf, size, 0)
            while (i >= 0) {
                val nalData = i + if (i + 3 < size && buf[i + 2] == 1.toByte()) 3 else 4
                val next = nextStartCode(buf, size, nalData)
                val nalEnd = if (next < 0) size else next
                if (nalHasHdr10PlusSei(buf, nalData, nalEnd - nalData)) return true
                i = next
            }
            return false
        }
        var off = 0
        while (off + 4 <= size) {
            val len = ((buf[off].toInt() and 0xFF) shl 24) or
                ((buf[off + 1].toInt() and 0xFF) shl 16) or
                ((buf[off + 2].toInt() and 0xFF) shl 8) or
                (buf[off + 3].toInt() and 0xFF)
            off += 4
            if (len <= 0 || off + len > size) break
            if (nalHasHdr10PlusSei(buf, off, len)) return true
            off += len
        }
        return false
    }

    private fun nextStartCode(buf: ByteArray, size: Int, from: Int): Int {
        var i = from
        while (i + 2 < size) {
            if (buf[i] == 0.toByte() && buf[i + 1] == 0.toByte() && buf[i + 2] == 1.toByte()) {
                return i
            }
            i++
        }
        return -1
    }

    /// True when this HEVC NAL unit is a SEI carrying ITU-T T.35 user data with
    /// country code 0xB5 and provider code 0x003C — the ST 2094-40 (HDR10+)
    /// dynamic-metadata signal. (Provider 0x0040 is Dolby Vision's ST 2094-20,
    /// which is handled by the codec check instead.)
    private fun nalHasHdr10PlusSei(buf: ByteArray, start: Int, len: Int): Boolean {
        if (len < 2) return false
        val nalType = ((buf[start].toInt() and 0xFF) shr 1) and 0x3F
        if (nalType != 39 && nalType != 40) return false // prefix/suffix SEI
        val end = start + len
        var i = start + 2
        while (i + 1 < end) {
            var payloadType = 0
            while (i < end && (buf[i].toInt() and 0xFF) == 0xFF) {
                payloadType += 255
                i++
            }
            if (i >= end) return false
            payloadType += buf[i].toInt() and 0xFF
            i++
            var payloadSize = 0
            while (i < end && (buf[i].toInt() and 0xFF) == 0xFF) {
                payloadSize += 255
                i++
            }
            if (i >= end) return false
            payloadSize += buf[i].toInt() and 0xFF
            i++
            if (payloadType == 4 && payloadSize >= 3 &&
                i + 3 <= end &&
                (buf[i].toInt() and 0xFF) == 0xB5 &&
                (buf[i + 1].toInt() and 0xFF) == 0x00 &&
                (buf[i + 2].toInt() and 0xFF) == 0x3C
            ) {
                return true
            }
            i += payloadSize
            if (i > end) return false
        }
        return false
    }

    /// True when this HEVC NAL unit is a SEI carrying static HDR10 metadata:
    /// payload type 137 (mastering display colour volume) or
    /// payload type 144 (content light level).
    private fun nalHasStaticHdrSei(buf: ByteArray, start: Int, len: Int): Boolean {
        if (len < 2) return false
        val nalType = ((buf[start].toInt() and 0xFF) shr 1) and 0x3F
        if (nalType != 39 && nalType != 40) return false // prefix/suffix SEI
        val end = start + len
        var i = start + 2
        while (i + 1 < end) {
            var payloadType = 0
            while (i < end && (buf[i].toInt() and 0xFF) == 0xFF) {
                payloadType += 255
                i++
            }
            if (i >= end) return false
            payloadType += buf[i].toInt() and 0xFF
            i++
            var payloadSize = 0
            while (i < end && (buf[i].toInt() and 0xFF) == 0xFF) {
                payloadSize += 255
                i++
            }
            if (i >= end) return false
            payloadSize += buf[i].toInt() and 0xFF
            i++
            if (payloadType == 137 || payloadType == 144) return true
            i += payloadSize
            if (i > end) return false
        }
        return false
    }

    /// Scans one encoded video sample for static HDR10 SEI (payload types
    /// 137 = mastering display colour volume, 144 = content light level).
    private fun sampleHasStaticHdrSei(buf: ByteArray, size: Int): Boolean {
        val annexB = (size >= 4 && buf[0] == 0.toByte() && buf[1] == 0.toByte() &&
            buf[2] == 1.toByte()) ||
            (size >= 5 && buf[0] == 0.toByte() && buf[1] == 0.toByte() &&
                buf[2] == 0.toByte() && buf[3] == 1.toByte())
        if (annexB) {
            var i = nextStartCode(buf, size, 0)
            while (i >= 0) {
                val nalData = i + if (i + 3 < size && buf[i + 2] == 1.toByte()) 3 else 4
                val next = nextStartCode(buf, size, nalData)
                val nalEnd = if (next < 0) size else next
                if (nalHasStaticHdrSei(buf, nalData, nalEnd - nalData)) return true
                i = next
            }
            return false
        }
        var off = 0
        while (off + 4 <= size) {
            val len = ((buf[off].toInt() and 0xFF) shl 24) or
                ((buf[off + 1].toInt() and 0xFF) shl 16) or
                ((buf[off + 2].toInt() and 0xFF) shl 8) or
                (buf[off + 3].toInt() and 0xFF)
            off += 4
            if (len <= 0 || off + len > size) break
            if (nalHasStaticHdrSei(buf, off, len)) return true
            off += len
        }
        return false
    }

    private fun scanForStaticHdr(
        path: String?,
        uri: String?,
        headers: Map<String, String>,
    ): Boolean {
        val extractor = MediaExtractor()
        try {
            when {
                path != null -> extractor.setDataSource(path)
                uri != null -> {
                    val u = android.net.Uri.parse(uri)
                    when (u.scheme) {
                        "file" -> u.path?.let { extractor.setDataSource(it) } ?: return false
                        "content" -> extractor.setDataSource(activity, u, null)
                        else -> extractor.setDataSource(activity, u, headers.ifEmpty { null })
                    }
                }
                else -> return false
            }
            var videoTrack = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("video/") == true) {
                    videoTrack = i
                    break
                }
            }
            if (videoTrack < 0) return false
            extractor.selectTrack(videoTrack)
            val buffer = ByteArray(512 * 1024)
            var samples = 0
            while (samples < 256) {
                val size = extractor.readSampleData(java.nio.ByteBuffer.wrap(buffer), 0)
                if (size <= 0) break
                if (sampleHasStaticHdrSei(buffer, size)) return true
                samples++
                val timeUs = extractor.sampleTime
                if (timeUs > 0 && timeUs > 4_000_000L) break
                extractor.advance()
            }
            return false
        } catch (_: Exception) {
            return false
        } finally {
            extractor.release()
        }
    }

    private fun probeHdr10(path: String?, uri: String?, headers: Map<String, String>) {
        Thread {
            try {
                if (scanForStaticHdr(path, uri, headers) && !hdr10Content) {
                    hdr10Content = true
                    handler.post { emit() }
                }
            } catch (_: Throwable) {
                // Best-effort probe; never let it affect playback.
            }
        }.apply { isDaemon = true }.start()
    }

    /// Parses chapters off the main thread and re-emits so the Dart side
    /// gains the chapters list once available. MKV via [MkvChapters], MP4
    /// (`moov/udta/chpl` Nero) via [Mp4Chapters]. Local files via
    /// `parse(path)`, SMB via `parseSmb`, WebDAV/generic HTTP via
    /// `parseHttp` (Range: bytes=0-8M). Best-effort: tries the format matching
    /// the file extension first, then falls back to the other container so
    /// extension-less or mislabelled files still surface chapters.
    private fun probeChapters(
        path: String?,
        uri: String?,
        headers: Map<String, String> = emptyMap(),
        allowSelfSigned: Boolean = false,
    ) {
        val isLocal = !path.isNullOrEmpty()
        val isSmb = !uri.isNullOrEmpty() && uri!!.startsWith("smb://", ignoreCase = true)
        val base = uri?.substringBefore('?')?.lowercase() ?: ""
        val isHttp = !isLocal && !isSmb && uri != null &&
            (uri.startsWith("http://", ignoreCase = true) ||
                uri.startsWith("https://", ignoreCase = true))
        val isFtp = !uri.isNullOrEmpty() && (uri!!.startsWith("ftp://", ignoreCase = true) ||
            uri.startsWith("sftp://", ignoreCase = true))
        val isHttpMkv = isHttp && (base.endsWith(".mkv") || base.endsWith(".mka") ||
            base.endsWith(".mk3d") || base.endsWith(".webm"))
        val isHttpMp4 = isHttp && (base.endsWith(".mp4") || base.endsWith(".mov") ||
            base.endsWith(".m4v") || base.endsWith(".m4a") || base.endsWith(".m4b") ||
            base.endsWith(".3gp"))
        val pathExt = path?.substringAfterLast('.', "")?.lowercase() ?: ""
        val isLocalMkv = isLocal && (pathExt == "mkv" || pathExt == "mka" || pathExt == "mk3d" || pathExt == "webm")
        val isLocalMp4 = isLocal && (pathExt == "mp4" || pathExt == "mov" || pathExt == "m4v" ||
            pathExt == "m4a" || pathExt == "m4b" || pathExt == "3gp")
        val smbExt = uri?.substringBefore('?')?.substringAfterLast('.', "")?.lowercase() ?: ""
        val isSmbMkv = isSmb && (smbExt == "mkv" || smbExt == "mka" || smbExt == "mk3d" || smbExt == "webm")
        val isSmbMp4 = isSmb && (smbExt == "mp4" || smbExt == "mov" || smbExt == "m4v" ||
            smbExt == "m4a" || smbExt == "m4b" || smbExt == "3gp")
        val isFtpMkv = isFtp && (base.endsWith(".mkv") || base.endsWith(".mka") ||
            base.endsWith(".mk3d") || base.endsWith(".webm"))
        val isFtpMp4 = isFtp && (base.endsWith(".mp4") || base.endsWith(".mov") ||
            base.endsWith(".m4v") || base.endsWith(".m4a") || base.endsWith(".m4b") ||
            base.endsWith(".3gp"))
        if (!isLocal && !isSmb && !isFtp && !isHttpMkv && !isHttpMp4) {
            // Unknown remote scheme (e.g. content://) — still probe local-like files
            // when a path is available, otherwise nothing to read.
            if (!isLocalMkv && !isLocalMp4 && isLocal) {
                // Fall through: extension-less local file — try both.
            } else if (!isLocal) return
        }
        Thread {
            try {
                val parsed: List<MkvChapters.Chapter> = when {
                    isLocalMp4 || isSmbMp4 || isHttpMp4 || isFtpMp4 -> {
                        val mp4: List<Mp4Chapters.Chapter> = when {
                            isLocal -> Mp4Chapters.parse(path!!)
                            isSmb -> Mp4Chapters.parseSmb(uri!!, activity)
                            isFtp -> Mp4Chapters.parseFtp(uri!!, activity)
                            else -> Mp4Chapters.parseHttp(uri!!, headers, allowSelfSigned)
                        }
                        if (mp4.isNotEmpty()) mp4.map { MkvChapters.Chapter(it.title, it.startMs, it.endMs) }
                        else {
                            // Fallback to MKV parser for mislabelled files.
                            when {
                                isLocal -> MkvChapters.parse(path!!)
                                isSmb -> MkvChapters.parseSmb(uri!!, activity)
                                isFtp -> MkvChapters.parseFtp(uri!!, activity)
                                else -> MkvChapters.parseHttp(uri!!, headers, allowSelfSigned)
                            }
                        }
                    }
                    isLocalMkv || isSmbMkv || isHttpMkv || isFtpMkv -> {
                        val mkv = when {
                            isLocal -> MkvChapters.parse(path!!)
                            isSmb -> MkvChapters.parseSmb(uri!!, activity)
                            isFtp -> MkvChapters.parseFtp(uri!!, activity)
                            else -> MkvChapters.parseHttp(uri!!, headers, allowSelfSigned)
                        }
                        if (mkv.isNotEmpty()) mkv
                        else {
                            val mp4: List<Mp4Chapters.Chapter> = when {
                                isLocal -> Mp4Chapters.parse(path!!)
                                isSmb -> Mp4Chapters.parseSmb(uri!!, activity)
                                isFtp -> Mp4Chapters.parseFtp(uri!!, activity)
                                else -> Mp4Chapters.parseHttp(uri!!, headers, allowSelfSigned)
                            }
                            mp4.map { MkvChapters.Chapter(it.title, it.startMs, it.endMs) }
                        }
                    }
                    isLocal -> {
                        // Extension-less or unknown local file — try MKV then MP4.
                        val mkv = MkvChapters.parse(path!!)
                        if (mkv.isNotEmpty()) mkv
                        else Mp4Chapters.parse(path).map { MkvChapters.Chapter(it.title, it.startMs, it.endMs) }
                    }
                    isSmb -> {
                        val mkv = MkvChapters.parseSmb(uri!!, activity)
                        if (mkv.isNotEmpty()) mkv
                        else Mp4Chapters.parseSmb(uri, activity).map { MkvChapters.Chapter(it.title, it.startMs, it.endMs) }
                    }
                    isFtp -> {
                        // Extension-less remote file — try MKV then MP4.
                        val mkv = MkvChapters.parseFtp(uri!!, activity)
                        if (mkv.isNotEmpty()) mkv
                        else Mp4Chapters.parseFtp(uri, activity).map { MkvChapters.Chapter(it.title, it.startMs, it.endMs) }
                    }
                    else -> {
                        val mkv = MkvChapters.parseHttp(uri!!, headers, allowSelfSigned)
                        if (mkv.isNotEmpty()) mkv
                        else Mp4Chapters.parseHttp(uri, headers, allowSelfSigned).map { MkvChapters.Chapter(it.title, it.startMs, it.endMs) }
                    }
                }
                if (parsed.isNotEmpty()) {
                    chapters = parsed
                    handler.post { emit() }
                }
            } catch (_: Throwable) {
                // Best-effort; never let it affect playback.
            }
        }.apply { isDaemon = true }.start()
    }

    init {
        playerView.player = player
        player.addListener(listener)
        playerView.keepScreenOn = true

        initialModeId = currentDisplay()?.mode?.modeId

        // Fire TV fix: lift the video SurfaceView above any dim layers the
        // framework inserts between dual SurfaceViews in the same window.
        // Combined with a transparent window background (set in MainActivity),
        // this lets the video show through — matching Nova Player's approach.
        (playerView.videoSurfaceView as? android.view.SurfaceView)
            ?.setZOrderMediaOverlay(true)

        methodChannel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "open" -> {
                    registerSpatialListenerOnce()
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
                    val allowSelfSigned = call.argument<Boolean>("allowSelfSigned") ?: false
                    httpDataSourceFactory.setPermissive(allowSelfSigned)
                    // A new media item: allow DV P5 rejection to fire again if
                    // this one is also Profile 5 on a DV-less device.
                    dvRejectionShown = false
                    hdr10PlusContent = false
                    hdr10Content = false
                    chapters = emptyList()
                    currentVideoDecoderName = null
                    // Reset any pinch-zoom from a previous session.
                    playerView.zoomScale = 1f
                    playerView.applyForced()
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
                            // Subtitle candidates: explicit subtitleUri wins,
                            // then external subtitles from the server (Jellyfin),
                            // then auto-paired siblings next to the video file.
                            val paired: List<File> = if (subtitleUri.isNullOrEmpty() && path != null) {
                                SubtitleFormats.findSiblingSubtitles(path)
                            } else {
                                emptyList()
                            }
                            val localCandidates = if (subtitleUri.isNullOrEmpty()) {
                                paired
                            } else if (subtitleUri.startsWith("smb://") ||
                                       subtitleUri.startsWith("http://") ||
                                       subtitleUri.startsWith("https://") ||
                                       subtitleUri.startsWith("content://") ||
                                       subtitleUri.startsWith("file://")) {
                                // Remote subtitle URI (SMB, WebDAV, HTTP) — pass
                                // as-is, not wrapped in File().
                                emptyList()
                            } else {
                                listOf(File(subtitleUri))
                            }
                            // External subtitles from the server (e.g. Jellyfin
                            // DeliveryUrl). These are remote HTTP URLs.
                            val rawExternalSubs =
                                call.argument<List<Map<String, Any>>>("externalSubtitles")
                            val externalConfigs = rawExternalSubs?.mapNotNull { entry ->
                                val url = entry["uri"] as? String ?: return@mapNotNull null
                                if (url.isEmpty()) return@mapNotNull null
                                val label = entry["label"] as? String ?: "Track"
                                val language = entry["language"] as? String ?: ""
                                val mimeType = entry["mimeType"] as? String
                                    ?: "application/x-subrip"
                                val isDefault = entry["isDefault"] as? Boolean == true
                                MediaItem.SubtitleConfiguration.Builder(
                                    android.net.Uri.parse(url),
                                )
                                    .setMimeType(mimeType)
                                    .setLanguage(language)
                                    .setRoleFlags(C.ROLE_FLAG_SUBTITLE)
                                    .setLabel(label)
                                    .setSelectionFlags(
                                        if (isDefault) C.SELECTION_FLAG_DEFAULT else 0,
                                    )
                                    .build()
                            } ?: emptyList()
                            // Local subtitles (siblings or explicit local subtitleUri).
                            val localConfigs = localCandidates.mapIndexed { i, sub ->
                                val originalUri = android.net.Uri.fromFile(sub)
                                val utf8Uri = SubtitleFormats.toUtf8(activity, originalUri)
                                val name = sub.name
                                val language = SubtitleFormats.languageFromFileName(name)
                                MediaItem.SubtitleConfiguration.Builder(utf8Uri)
                                    .setMimeType(SubtitleFormats.mimeTypeFor(name))
                                    .setLanguage(language)
                                    .setRoleFlags(C.ROLE_FLAG_SUBTITLE)
                                    .setLabel(SubtitleFormats.labelFromFileName(name))
                                    .setSelectionFlags(
                                        if (i == 0) C.SELECTION_FLAG_DEFAULT else 0,
                                    )
                                    .build()
                            }
                            // Remote explicit subtitleUri (smb://, http://, content://, file://).
                            val remoteExplicitConfig = if (!subtitleUri.isNullOrEmpty() &&
                                localCandidates.isEmpty()
                            ) {
                                val ext = subtitleUri.substringAfterLast('.', "srt")
                                val mimeType = SubtitleFormats.mimeTypeFor("file.$ext")
                                val rawUri = android.net.Uri.parse(subtitleUri)
                                // content:// / file:// from CX / system picker need
                                // to be copied to a UTF-8 cache file so Media3 can
                                // read them reliably (CX's SMB content provider
                                // isn't directly readable by ExoPlayer's DataSource).
                                val finalUri = if (subtitleUri.startsWith("content://") ||
                                    subtitleUri.startsWith("file://")) {
                                    SubtitleFormats.toUtf8(activity, rawUri)
                                } else {
                                    rawUri
                                }
                                listOf(
                                    MediaItem.SubtitleConfiguration.Builder(finalUri)
                                        .setMimeType(mimeType)
                                        .setRoleFlags(C.ROLE_FLAG_SUBTITLE)
                                        .setLabel("Subtitle")
                                        .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                                        .build(),
                                )
                            } else {
                                emptyList()
                            }
                            val allConfigs = localConfigs + remoteExplicitConfig + externalConfigs
                            if (allConfigs.isNotEmpty()) {
                                currentSubtitle = if (localCandidates.isNotEmpty()) {
                                    localCandidates.first().absolutePath to
                                        SubtitleFormats.labelFromFileName(
                                            localCandidates.first().name,
                                        )
                                } else {
                                    val first = rawExternalSubs?.firstOrNull()
                                    (first?.get("uri") as? String ?: "") to
                                        (first?.get("label") as? String ?: "Track")
                                }
                                setSubtitleConfigurations(allConfigs)
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
                    probeHdr10Plus(path, uri, headers)
                    probeHdr10(path, uri, headers)
                    probeChapters(path, uri, headers, allowSelfSigned)
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
                "setSubtitleStyle" -> {
                    applySubtitleStyle(
                        (call.argument<Number>("size")?.toDouble()) ?: 1.0,
                        call.argument<Number>("color")?.toInt() ?: 0xFFFFFFFF.toInt(),
                        call.argument<Number>("bg")?.toInt() ?: 0x80000000.toInt(),
                        call.argument<Boolean>("outline") ?: true,
                        (call.argument<Number>("delayMs")?.toLong()) ?: 0L,
                    )
                    result.success(null)
                }
                "setResizeMode" -> {
                    applyFitMode(call.argument<Number>("mode")?.toInt() ?: 0)
                    result.success(null)
                }
                "setSpeed" -> {
                    val speed = (call.argument<Number>("speed")?.toDouble() ?: 1.0)
                        .toFloat()
                        .coerceIn(0.25f, 4f)
                    player.setPlaybackSpeed(speed)
                    result.success(null)
                }
                "setBrightness" -> {
                    val brightness = call.argument<Number>("brightness")?.toFloat() ?: 0.5f
                    val params = activity.window.attributes
                    // -1 = restore system default (BRIGHTNESS_OVERRIDE_NONE).
                    params.screenBrightness = if (brightness < 0)
                        android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    else
                        brightness.coerceIn(0f, 1f)
                    activity.window.attributes = params
                    result.success(null)
                }
                "getBrightness" -> {
                    val b = activity.window.attributes.screenBrightness
                    result.success(if (b < 0) 0.5f else b)
                }
                "getSystemVolume" -> {
                    val am = activity.getSystemService(Context.AUDIO_SERVICE)
                            as android.media.AudioManager
                    val maxVol = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                        .toFloat()
                    val curVol = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                        .toFloat()
                    result.success(if (maxVol > 0) curVol / maxVol else 1f)
                }
                "setSystemVolume" -> {
                    val volume = call.argument<Number>("volume")?.toFloat() ?: 1f
                    val am = activity.getSystemService(Context.AUDIO_SERVICE)
                            as android.media.AudioManager
                    val maxVol = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                    val target = Math.round(volume.coerceIn(0f, 1f) * maxVol).toInt()
                    am.setStreamVolume(android.media.AudioManager.STREAM_MUSIC, target, 0)
                    result.success(null)
                }
                "setAudioBoost" -> {
                    val boost = call.argument<Number>("boost")?.toFloat() ?: 1.0f
                    audioBoost = boost.coerceIn(1.0f, 3.0f)
                    activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .edit().putFloat("flutter.dreamplayer.audioBoost", audioBoost).apply()
                    applyAudioEffects()
                    emit()
                    result.success(null)
                }
                "setNightMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    nightModeEnabled = enabled
                    activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .edit().putBoolean("flutter.dreamplayer.nightMode", enabled).apply()
                    applyAudioEffects()
                    emit()
                    result.success(null)
                }
                "setBassBoost" -> {
                    val level = (call.argument<Number>("level")?.toInt() ?: 0).coerceIn(0, 3)
                    bassBoostLevel = level
                    activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .edit().putInt("flutter.dreamplayer.bassBoost", level).apply()
                    applyAudioEffects()
                    emit()
                    result.success(null)
                }
                "setZoom" -> {
                    val scale = (call.argument<Number>("scale")?.toDouble() ?: 1.0)
                        .toFloat()
                        .coerceIn(1.0f, 3.0f)
                    playerView.zoomScale = scale
                    playerView.applyForced()
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
    private fun applyHdrHeadroom(
        desired: Float,
        colorTransfer: Int,
        skipWindowHdr: Boolean = false,
    ) {
        // The whole HDR window pipeline needs the API 33+ surface APIs: the
        // window color mode alone (API 26) does NOT tag the video layer as HDR
        // — without the TIRAMISU `setDataSpace(SurfaceControl, Int)` call the
        // SurfaceFlinger layer still reports `dataspace=UNKNOWN (0) hdr
        // metadata types=0` (verified on a Redmi Note 10, API 31 / MIUI), so
        // the PQ video is composited as SDR inside an HDR-mode window →
        // washed-out colors + a client-composed path that stutters 4K60.
        // Where the tag cannot be set, stay in the default color mode and let
        // SurfaceFlinger auto-tone-map HDR→SDR (correct, if not boosted).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        // Dolby Vision content skips the forced window HDR machinery entirely:
        // with the hybrid-composition platform view (see exo_player.dart) the
        // video's `SurfaceView` is now a real layer on the physical HDR panel,
        // and the decoder's own output carries the correct BT.2020 PQ dataspace
        // + TP10 buffer — device-composited exactly like Just Player (verified
        // on-device: `composition type=DEVICE`, `dataspace=BT2020_ITU_PQ`,
        // `whitePointNits=1249.99`, display in DISPLAY_P3). Forcing COLOR_MODE_HDR
        // / headroom / setDataSpace on top was the old virtual-display workaround
        // and we have never needed it once the surface reaches the panel natively.
        // Non-DV HDR10/HDR10+/HLG still uses the full headroom path below (the
        // OPLUS EDR brightness ramp, verified on the HDR10+ lake clip).
        if (skipWindowHdr) return
        // SDR-only panels must NOT be pushed into COLOR_MODE_HDR or given a PQ
        // dataspace: on non-HDR displays Android's SurfaceFlinger tone-maps
        // HDR→SDR itself, and forcing the HDR window color mode / surface
        // dataspace on such a panel would break that conversion (washed-out or
        // wrong colors). Only engage the headroom path when the panel actually
        // reports an HDR capability.
        val display = activity.display ?: return
        if (display.hdrCapabilities?.supportedHdrTypes?.isNotEmpty() != true) return
        val window = activity.window ?: return
        val mode =
            if (desired > 1.0f) ActivityInfo.COLOR_MODE_HDR else ActivityInfo.COLOR_MODE_DEFAULT
        if (window.colorMode != mode) {
            window.colorMode = mode
        }
        if (desired != hdrHeadroomSet) {
            window.setDesiredHdrHeadroom(desired)
            hdrHeadroomSet = desired
        }
        // The two-arg `SurfaceControl.Transaction.setDataSpace(SurfaceControl, Int)`
        // overload is API 33+ (Tiramisu) — the single-arg `setDataSpace(Int)` is API 29.
        // On API 29-32 (e.g. Android 12 devices) the two-arg overload does not exist and
        // would throw NoSuchMethodError (verified on a Redmi Note 10, API 31 / MIUI).
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
        //
        // Some DV profile-7/8 MKVs omit the MKV `Colour` element entirely — the
        // PQ/BT.2020 color info lives only in the HEVC SPS VUI, which Media3's
        // MatroskaExtractor never parses, so `colorInfo` comes back null even
        // though the content is HDR (verified on-device: `dvhe.08.06` track,
        // colorInfo=null, while the SurfaceFlinger video layer composites as
        // BT2020_ITU_PQ). Dolby Vision is always HDR (every profile — the base
        // layer is PQ BT.2020 for profiles 4/7/8 and IPTPQc2 for 5), so treat
        // a `dvhe`/`dvh1`/`dvav` codec as HDR regardless of the reported color
        // info. This is exactly the heuristic `detectMedia3HdrFormat` on the
        // Dart side already uses for the chip label.
        //
        // Similarly, plain HDR10 MKVs may omit the MKV `Colour` element — the
        // PQ/BT.2020 info lives only in the HEVC SPS VUI. We probe the bitstream
        // for static HDR10 SEI (payload types 137/144) and treat it as HDR10
        // when Media3's colorInfo is missing.
        val colorTransfer = videoFormat?.colorInfo?.colorTransfer
        val codecs = videoFormat?.codecs
        val isDolbyVision = codecs?.let { Regex("dv(?:he|h1|av)\\.").containsMatchIn(it) } == true
        applyHdrHeadroom(
            when {
                colorTransfer == C.COLOR_TRANSFER_ST2084 ||
                    colorTransfer == C.COLOR_TRANSFER_HLG -> 5.0f
                isDolbyVision -> 5.0f
                hdr10Content -> 5.0f
                else -> 1.0f
            },
            colorTransfer ?: -1,
            skipWindowHdr = isDolbyVision,
        )

        // Override colorTransfer for the Dart chip when we detected HDR10 via
        // bitstream probe but Media3's colorInfo was null.
        val emittedColorTransfer = if (hdr10Content && colorTransfer == null)
            C.COLOR_TRANSFER_ST2084
        else
            colorTransfer

        val map = HashMap<String, Any?>()
        map["state"] = state
        map["playing"] = player.isPlaying
        map["positionMs"] = player.currentPosition
        map["durationMs"] = if (player.duration == C.TIME_UNSET) 0L else player.duration
        map["bufferedMs"] = player.bufferedPosition
        map["buffering"] = state == Player.STATE_BUFFERING
        map["ended"] = state == Player.STATE_ENDED
        map["videoCodecs"] = videoFormat?.codecs
        map["videoMime"] = videoFormat?.sampleMimeType
        map["videoWidth"] = videoSize.width
        map["videoHeight"] = videoSize.height
        map["colorTransfer"] = emittedColorTransfer
        map["isHdr10Plus"] = hdr10PlusContent
        map["isHdr10"] = hdr10Content
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
        map["videoDecoderName"] = currentVideoDecoderName
        map["isHwDecoder"] = currentVideoDecoderName?.let { !isSoftwareDecoder(it) }
        map["error"] = errorCodeName
        map["errorMessage"] = errorMessage
        map["errorCause"] = errorCause
        map["audioPassthrough"] = passthroughEnabled
        map["audioBoost"] = audioBoost
        map["nightMode"] = nightModeEnabled
        map["bassBoost"] = bassBoostLevel
        map["spatialAudio"] = spatialStatus()
        if (chapters.isNotEmpty()) {
            map["chapters"] = chapters.map {
                mapOf(
                    "title" to it.title,
                    "startMs" to it.startMs,
                    "endMs" to (it.endMs ?: -1L),
                )
            }
        }
        return map
    }

    private fun isSoftwareDecoder(name: String): Boolean {
        val n = name.lowercase()
        return n.contains("google") || n.contains("ffmpeg") || n.startsWith("c2.android.")
    }

    private fun emit(
        errorCodeName: String? = null,
        errorMessage: String? = null,
        errorCause: String? = null,
    ) {
        var name = errorCodeName
        var message = errorMessage
        if (name == null) {
            val dv = dvP5Rejection()
            if (dv != null) {
                name = dv.first
                message = dv.second
            }
        }
        sink?.success(stateMap(name, message, errorCause))
    }

    override fun getView(): View = playerView

    /// Applies the Dart-side [VideoFitMode] to the surface. Fixed ratios
    /// (16:9 / 4:3) force the content frame's aspect ratio and zoom-crop into
    /// it; the others map 1:1 to Media3 resize modes.
    /// Applies the user's subtitle appearance to Media3's SubtitleView.
    /// Size is a multiplier around Media3's default fractional text size.
    /// `delayMs` is stored globally so the next `open()`'s parsers shift every
    /// cue (positive = later; requires re-open to take effect mid-playback).
    private fun applySubtitleStyle(sizeMult: Double, color: Int, bg: Int, outline: Boolean, delayMs: Long = 0L) {
        SubtitleTiming.delayUs = delayMs * 1000L
        val view = playerView.subtitleView ?: return
        view.setFractionalTextSize(
            SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * sizeMult.coerceIn(0.6, 2.0).toFloat()
        )

        val hasBg = (bg ushr 24) != 0
        val edgeType = if (outline)
            CaptionStyleCompat.EDGE_TYPE_OUTLINE
        else
            CaptionStyleCompat.EDGE_TYPE_NONE
        val style = CaptionStyleCompat(
            color,
            if (hasBg) bg else Color.TRANSPARENT,
            Color.TRANSPARENT,
            edgeType,
            if (outline) Color.BLACK else Color.TRANSPARENT,
            null,
        )
        view.setStyle(style)
    }

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

    private fun currentDisplay(): android.view.Display? =
        (activity.getSystemService(Context.DISPLAY_SERVICE) as?
            android.hardware.display.DisplayManager)
            ?.getDisplay(android.view.Display.DEFAULT_DISPLAY)

    /// Switches the panel to the supported refresh mode closest to the video's
    /// frame rate (23.976 → a 24/60 Hz mode instead of staying at the
    /// startup-selected max), matching motion cadence to content like Just
    /// Player / mpv do. Only fires when a candidate is meaningfully closer to
    /// the content fps than the current mode; [restoreRefreshRate] undoes it
    /// when the view is disposed. Resolution modes are filtered so only the
    /// refresh rate changes.
    private fun matchRefreshRate() {
        val fps = player.videoFormat?.frameRate ?: return
        if (fps <= 0f || fps.isNaN()) return
        val display = currentDisplay() ?: return
        val current = display.mode
        val candidates = display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth &&
                it.physicalHeight == current.physicalHeight
        }
        val best = candidates.minByOrNull { kotlin.math.abs(it.refreshRate - fps) } ?: return
        val curErr = kotlin.math.abs(current.refreshRate - fps)
        val bestErr = kotlin.math.abs(best.refreshRate - fps)
        // Stay put when already within rounding distance of the content
        // (59.94-vs-60 style) or when no candidate beats the current mode.
        if (best.modeId == current.modeId || curErr < 0.5f || bestErr >= curErr) return
        runCatching {
            val params = activity.window.attributes
            params.preferredDisplayModeId = best.modeId
            activity.window.attributes = params
        }
    }

    private fun restoreRefreshRate() {
        val id = initialModeId ?: return
        runCatching {
            val params = activity.window.attributes
            if (params.preferredDisplayModeId != id) {
                params.preferredDisplayModeId = id
                activity.window.attributes = params
            }
        }
    }

    override fun dispose() {
        restoreRefreshRate()
        stopPositionTicker()
        unregisterSpatialListener()
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        loudnessEnhancer = null
        try { bassBoostFx?.release() } catch (_: Exception) {}
        bassBoostFx = null
        player.removeListener(listener)
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        player.release()
        playerView.player = null
    }

    companion object {
        private const val BUFFER_FOR_PLAYBACK_MS = 1_500
        private const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 2_000
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

    /// Pinch-to-zoom crop scale (1.0 = fit, up to 3.0). Applied as a scale
    /// transform on the content frame so the video zooms around its center.
    var zoomScale: Float = 1f

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
        frame.scaleX = zoomScale
        frame.scaleY = zoomScale
    }
}
