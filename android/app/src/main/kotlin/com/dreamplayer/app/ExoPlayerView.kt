package com.dreamplayer.app

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.graphics.Color
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
    /// [SmbDataSource] for `smb://` or to [local] for everything else.
    private class MultiplexDataSource(
        private val local: DefaultDataSource.Factory,
        private val context: Context,
    ) : BaseDataSource(/* isNetwork= */ true) {
        private var delegate: DataSource? = null

        override fun open(dataSpec: DataSpec): Long {
            delegate = if (dataSpec.uri.scheme == "smb") {
                SmbDataSource(context)
            } else {
                local.createDataSource()
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

    init {
        playerView.player = player
        player.addListener(listener)
        playerView.keepScreenOn = true

        // Fire TV fix: lift the video SurfaceView above any dim layers the
        // framework inserts between dual SurfaceViews in the same window.
        // Combined with a transparent window background (set in MainActivity),
        // this lets the video show through — matching Nova Player's approach.
        (playerView.videoSurfaceView as? android.view.SurfaceView)
            ?.setZOrderMediaOverlay(true)

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
                    // A new media item: allow DV P5 rejection to fire again if
                    // this one is also Profile 5 on a DV-less device.
                    dvRejectionShown = false
                    hdr10PlusContent = false
                    hdr10Content = false
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
                    probeHdr10Plus(path, uri, headers)
                    probeHdr10(path, uri, headers)
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
                    )
                    result.success(null)
                }
                "setResizeMode" -> {
                    applyFitMode(call.argument<Number>("mode")?.toInt() ?: 0)
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
            android.util.Log.d("DreamPlayerHDR", "setColorMode($mode)")
        }
        if (desired != hdrHeadroomSet) {
            window.setDesiredHdrHeadroom(desired)
            android.util.Log.d("DreamPlayerHDR", "setDesiredHdrHeadroom($desired)")
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
            android.util.Log.d(
                "DreamPlayerHDR",
                "setSurfaceDataSpace(0x${Integer.toHexString(dataSpace)})",
            )
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
        map["error"] = errorCodeName
        map["errorMessage"] = errorMessage
        map["errorCause"] = errorCause
        map["audioPassthrough"] = passthroughEnabled
        return map
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
    private fun applySubtitleStyle(sizeMult: Double, color: Int, bg: Int, outline: Boolean) {
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

    override fun dispose() {
        stopPositionTicker()
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
