package com.dreamplayer.app

import android.content.Context
import android.os.Handler
import android.util.Log
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegAudioRenderer
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import java.util.ArrayList

class DreamRenderersFactory(context: Context) : DefaultRenderersFactory(context) {
    init {
        setAllowedVideoJoiningTimeMs(0L)
    }

    companion object {
        /// Manual A/V sync: shifts audio relative to video (±5 s). Shared so
        /// the `setAudioDelay` channel handler can retune it mid-playback.
        val audioDelayProcessor = AudioDelayProcessor()
    }

    /// Inserts the audio-delay processor into every audio sink (platform and
    /// FFmpeg renderers both receive this sink from buildAudioRenderers).
    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioTrackPlaybackParams: Boolean,
    ): AudioSink =
        DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(enableFloatOutput)
            .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
            .setAudioProcessors(arrayOf(audioDelayProcessor))
            .build()

    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        codecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
    ) {
        super.buildVideoRenderers(
            context,
            extensionRendererMode,
            codecSelector,
            enableDecoderFallback,
            eventHandler,
            eventListener,
            allowedJoiningTimeMs,
            out,
        )
        // Add FfmpegVideoRenderer as ultimate fallback (after all MediaCodec
        // renderers). Used when hardware + software MediaCodec decoders both
        // fail (e.g. 10-bit HEVC on devices without 10-bit MediaCodec support).
        // Added at the END so HDR/DV hardware path stays primary.
        // Constructor: (allowedJoiningTimeMs, handler, eventListener, maxDroppedFramesToNotify)
        try {
            out.add(FfmpegVideoRenderer(allowedJoiningTimeMs, eventHandler, eventListener, 0))
            Log.i("DreamRenderersFactory", "Loaded FfmpegVideoRenderer as fallback.")
        } catch (e: Exception) {
            Log.w("DreamRenderersFactory", "FfmpegVideoRenderer unavailable, falling back to MediaCodec only.", e)
        }
    }

    override fun buildAudioRenderers(
        context: Context,
        extensionRendererMode: Int,
        codecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        audioSink: AudioSink,
        eventHandler: Handler,
        eventListener: AudioRendererEventListener,
        out: ArrayList<Renderer>,
    ) {
        super.buildAudioRenderers(
            context,
            extensionRendererMode,
            codecSelector,
            enableDecoderFallback,
            audioSink,
            eventHandler,
            eventListener,
            out,
        )
        try {
            out.add(FfmpegAudioRenderer(eventHandler, eventListener, audioSink))
            Log.i("DreamRenderersFactory", "Loaded FfmpegAudioRenderer.")
        } catch (e: Exception) {
            Log.w("DreamRenderersFactory", "FfmpegAudioRenderer unavailable, falling back to MediaCodec only.", e)
        }
    }
}
