package com.example.dream_player

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import jcifs.smb.SmbFile
import jcifs.smb.SmbRandomAccessFile
import java.io.IOException

/// ExoPlayer DataSource that streams a file straight off an SMB share
/// (no local download). URIs look like `smb://<serverId>/<share>/<path...>`;
/// the `<serverId>` resolves to the saved server + encrypted credentials in
/// [SmbStore], so passwords never appear in the URI or on the Dart side.
///
/// The SMB engine is **jcifs-ng** (the library Nova and CX File Explorer use).
/// vs the previous smbj: jcifs-ng decodes each SMB2 read response directly into
/// our buffer (no per-read byte[] allocation / GC churn), sizes each read to the
/// server's negotiated MaxReadSize, and pipelines requests over an SMB2 credit
/// window — CX hits ~75 MB/s with it where smbj gave us ~4-6 MB/s.
///
/// Three things make this usable for real playback:
///  1. The connection + file handle are REUSED across open() calls for the same
///     URI. Media3's extractors (esp. Matroska/MKV) seek aggressively while they
///     build their index — the MKV Cues live at the end of the file — so a fresh
///     SMB connect per open() stalls playback for seconds. We only reconnect when
///     the target server/share/path actually changes.
///  2. The MKV extractor parses element headers byte-by-byte (1-3 byte reads),
///     which would otherwise be one SMB2 round-trip per byte. A read-ahead ring
///     buffer serves those tiny reads straight out of memory.
///  3. A large ASYNC prefetch buffer (Nova-style read-ahead cache). A dedicated
///     `smb-prefetch` thread keeps the ring filled up to [BUFFER_CAPACITY] ahead
///     of the playhead, so transient Wi-Fi jitter to the NAS never reaches the
///     decoder. This mirrors Nova's engine: a 48 MB ring buffer (`avos_mp_video.c`
///     `stream_set_buffer_size(video->s, 48)`) refilled by a background pthread
///     that keeps >= 5 s of media ahead of the parser (`stream_drive_wake_sleep`).
@UnstableApi
class SmbDataSourceFactory(private val context: Context) : DataSource.Factory {
    override fun createDataSource(): DataSource = SmbDataSource(context)
}

@UnstableApi
class SmbDataSource(private val context: Context) : BaseDataSource(true) {

    // ---- SMB connection state (guarded by smbLock) ----
    private var file: SmbFile? = null
    private var raf: SmbRandomAccessFile? = null
    private var fileKey: String? = null
    private var openedUri: Uri? = null
    /// Non-SMB scheme (http/https proxy) delegation. `DefaultDataSource` routes
    /// every scheme other than file/content/asset through its base factory, so
    /// this source must also serve http(s) — e.g. file managers that stream SMB
    /// files to players through a local HTTP proxy (CX Explorer hands out
    /// `http://127.0.0.1:<port>/SMB/...`). Lazily created, reused across opens.
    private var httpDataSource: HttpDataSource? = null
    private var httpMode = false
    /// File size cached on connect so a reused handle doesn't re-stat (and
    /// doesn't accidentally report 0 for seeks on the already-open file).
    private var cachedFileSize: Long = 0

    // Reconnect parameters (set on open(), used by the prefetch thread to
    // re-establish the handle after a NAS drop).
    private var savedKey: String? = null
    private var savedCreds: SmbCredentials? = null
    private var savedShare: String? = null
    private var savedPath: String? = null

    private val smbLock = Object()

    // ---- read-ahead ring buffer (guarded by ringLock) ----
    //
    // Layout is a classic circular buffer: [bufStart, bufStart + valid) holds
    // the valid bytes (wrapping around the physical array), and the playhead
    // `position` always lies inside it. The prefetch thread writes at
    // bufStart + valid and the reader consumes from `position`.
    private var ring: ByteArray? = null
    private var ringSize = 0
    private var bufStart: Long = 0
    private var valid: Long = 0
    private var bufEof = false
    private var fileSize: Long = 0
    private var position: Long = 0

    private val ringLock = Object()
    private var prefetcher: Thread? = null
    private var prefetchKilled = false
    /// Bumped whenever the prefetch thread must exit (close/new open) — a
    /// thread loops with its own captured generation and dies on mismatch.
    private var prefetchGen = 0L
    /// Bumped whenever the ring window is reset (open on a new position). An
    /// in-flight SMB read belongs to the old window and its result is dropped.
    private var ringEpoch = 0L

    override fun open(dataSpec: DataSpec): Long {
        openedUri = dataSpec.uri
        if (!"smb".equals(dataSpec.uri.scheme, ignoreCase = true)) {
            // http/https (or anything else) — delegate to the platform HTTP
            // source instead of throwing "Unknown SMB server".
            httpMode = true
            val http = httpDataSource
                ?: DefaultHttpDataSource.Factory().createDataSource().also {
                    httpDataSource = it
                }
            transferInitializing(dataSpec)
            val length = http.open(dataSpec)
            transferStarted(dataSpec)
            return length
        }
        httpMode = false
        transferInitializing(dataSpec)
        val uri = dataSpec.uri
        val serverId = uri.host
            ?: throw IOException("Malformed SMB uri: $uri")
        val segments = uri.pathSegments
        if (segments.isEmpty()) throw IOException("Missing share in SMB uri: $uri")
        val shareName = segments[0]
        val remotePath =
            if (segments.size > 1) segments.subList(1, segments.size).joinToString("/") else ""

        val creds = SmbStore.resolve(context, serverId)
            ?: throw IOException("Unknown SMB server '$serverId'")

        val key = "$serverId/$shareName/$remotePath"

        try {
            val size: Long
            synchronized(smbLock) {
                savedKey = key
                savedCreds = creds
                savedShare = shareName
                savedPath = remotePath
                if (file == null || fileKey != key) {
                    val t0 = System.nanoTime()
                    size = connectLocked(key, creds, shareName, remotePath)
                    val ms = (System.nanoTime() - t0) / 1_000_000
                    Log.i(TAG, "open: connected in ${ms}ms, size=$size")
                } else {
                    size = cachedFileSize
                }
            }

            synchronized(ringLock) {
                fileSize = size
                val withinWindow = fileKey == key && valid > 0 &&
                    dataSpec.position >= bufStart && dataSpec.position < bufStart + valid
                if (!withinWindow) {
                    // New position outside the buffered window (or first open):
                    // drop everything and start prefetching from the new offset.
                    // An in-flight prefetch read belongs to the old window and
                    // will be discarded via ringEpoch.
                    ringEpoch++
                    ensureRingCapacity()
                    val hadData = valid
                    position = dataSpec.position
                    bufStart = position
                    valid = 0
                    bufEof = false
                    if (hadData > 0) {
                        Log.w(
                            TAG,
                            "open: window RESET pos=$position (was ${bufStart - position + hadData}..${bufStart + hadData} had $hadData bytes)",
                        )
                    }
                } else {
                    // Seek-back within the buffered data (Nova set_pos without
                    // force_reload): keep the window, just move the playhead.
                    position = dataSpec.position
                    Log.i(TAG, "open: seek within buffer, keeping ${valid} bytes at ${bufStart}")
                }
                if (prefetcher == null || !prefetcher!!.isAlive) startPrefetcher()
                ringLock.notifyAll()
            }

            val length =
                if (dataSpec.length != C.LENGTH_UNSET.toLong())
                    dataSpec.length
                else
                    size - dataSpec.position
            transferStarted(dataSpec)
            return length
        } catch (e: Exception) {
            close()
            throw IOException("SMB open failed: ${e.message}", e)
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (httpMode) {
            val http = httpDataSource ?: return C.RESULT_END_OF_INPUT
            val n = http.read(buffer, offset, length)
            if (n > 0) bytesTransferred(n)
            return n
        }
        if (length == 0) return 0
        val t0 = System.nanoTime()
        val n: Int
        synchronized(ringLock) {
            if (position >= bufStart + valid && !bufEof) {
                val waitStart = System.currentTimeMillis()
                Log.w(TAG, "read: RING EMPTY at pos=$position, waiting for prefetch...")
                while (position >= bufStart + valid && !bufEof) {
                    ringLock.wait()
                }
                Log.w(TAG, "read: resumed after ${System.currentTimeMillis() - waitStart}ms")
            }
            if (position >= bufStart + valid) return C.RESULT_END_OF_INPUT
            val r = ring ?: return C.RESULT_END_OF_INPUT
            val available = minOf(length.toLong(), bufStart + valid - position).toInt()
            val rel = (position - bufStart).toInt()
            val fromIdx = idx(bufStart + rel)
            val first = minOf(available, ringSize - fromIdx)
            System.arraycopy(r, fromIdx, buffer, offset, first)
            if (available > first) {
                System.arraycopy(r, 0, buffer, offset + first, available - first)
            }
            position += available
            n = available
            ringLock.notifyAll()
        }
        if (n > 0) {
            bytesTransferred(n)
            val us = (System.nanoTime() - t0) / 1_000
            Log.v(TAG, "read: pos=${position - n} n=$n in ${us}us")
        }
        return n
    }

    override fun getUri(): Uri? =
        if (httpMode) httpDataSource?.uri ?: openedUri else openedUri

    override fun close() {
        if (httpMode) {
            httpMode = false
            try { httpDataSource?.close() } catch (_: IOException) {}
            openedUri = null
            return
        }
        Log.i(TAG, "close: stopping prefetcher + releasing handles")
        synchronized(ringLock) {
            prefetchKilled = true
            prefetchGen++
            ringLock.notifyAll()
        }
        val p = prefetcher
        if (p != null) {
            try { p.join(2000) } catch (_: InterruptedException) {}
            if (p.isAlive) {
                // Still blocked in an SMB read (stalled NAS). Closing the file
                // makes the read throw so the thread can exit; don't wait on
                // smbLock for it (that could stall close() for the full SMB
                // socket timeout).
                Log.w(TAG, "close: prefetch thread busy, closing file to unblock")
                try { raf?.close() } catch (_: Exception) {}
            }
        }
        prefetcher = null
        synchronized(smbLock) {
            closeHandles()
        }
        synchronized(ringLock) {
            prefetchKilled = false
            valid = 0
            position = 0
            bufEof = false
            fileSize = 0
        }
        openedUri = null
    }

    /// Opens the SmbFile + SmbRandomAccessFile for [key] and returns the file
    /// length. Caller holds smbLock.
    private fun connectLocked(
        key: String,
        creds: SmbCredentials,
        share: String,
        path: String,
    ): Long {
        closeHandles()
        val f = SmbFile(smbUrl(creds, share, path), creds.context())
        val r = SmbRandomAccessFile(f, "r")
        file = f
        raf = r
        fileKey = key
        cachedFileSize = r.length()
        return cachedFileSize
    }

    /// jcifs-ng URLs are passed through verbatim (no percent-encoding — the
    /// library never URL-decodes, so a literal `%20` would be transmitted as
    /// such). Spaces, non-ASCII and `#` are all fine raw; a `?` in a filename
    /// is the one character the URL parser treats as a query separator and
    /// would be dropped — rare enough to be an accepted limitation.
    private fun smbUrl(creds: SmbCredentials, share: String, path: String): String {
        val base = "smb://${creds.host}:${creds.port}/$share"
        return if (path.isEmpty()) base else "$base/$path"
    }

    /// Allocates the ring lazily (first open only). Sizing is capped by file
    /// size so a small subtitle stream doesn't grab a 96 MB buffer.
    private fun ensureRingCapacity() {
        if (ring != null && ringSize > 0) return
        val target = minOf(BUFFER_CAPACITY.toLong(), maxOf(MIN_BUFFER_CAPACITY.toLong(), fileSize))
            .toInt()
        ring = ByteArray(target)
        ringSize = target
        Log.i(TAG, "ring allocated: ${ringSize / (1024 * 1024)} MiB")
    }

    private fun startPrefetcher() {
        prefetchKilled = false
        val gen = ++prefetchGen
        val t = Thread {
            prefetchLoop(gen)
        }
        t.isDaemon = true
        t.name = "smb-prefetch"
        t.start()
        prefetcher = t
    }

    private fun prefetchLoop(gen: Long) {
        var lastHeartbeat = System.currentTimeMillis()
        var bytesSinceHeartbeat = 0L
        while (true) {
            var readAt = 0L
            var readLen = 0
            var epoch = 0L
            synchronized(ringLock) {
                while (true) {
                    if (prefetchKilled || gen != prefetchGen) return
                    if (bufEof) { ringLock.wait(); continue }
                    // Drop the consumed prefix so the window can slide forward
                    // and free up capacity again.
                    val consumed = (position - bufStart).coerceAtLeast(0)
                    if (consumed > 0) {
                        bufStart = position
                        valid -= consumed
                    }
                    val room = ringSize.toLong() - valid
                    if (room > 0) {
                        readAt = bufStart + valid
                        readLen = minOf(room, SMB_CHUNK.toLong()).toInt()
                        // Keep the write within one physical segment of the ring.
                        readLen = minOf(readLen, ringSize - idx(readAt))
                        epoch = ringEpoch
                        break
                    }
                    ringLock.wait()
                }
            }

            var got = -2
            val readStart = System.nanoTime()
            synchronized(smbLock) {
                val r = raf
                if (r != null) {
                    try {
                        r.seek(readAt)
                        got = r.read(ring!!, idx(readAt), readLen)
                    } catch (e: Exception) {
                        if (!prefetchKilled) Log.w(TAG, "read error at $readAt: ${e.message}")
                        got = -2
                    }
                }
            }

            if (got > 0) {
                val readMs = (System.nanoTime() - readStart) / 1_000_000
                if (readMs > 800) {
                    Log.w(
                        TAG,
                        "slow read: $got bytes in ${readMs}ms at $readAt -> " +
                            String.format("%.1f MB/s", got / 1024.0 / 1024.0 / (readMs / 1000.0)),
                    )
                }
                synchronized(ringLock) {
                    if (epoch == ringEpoch) {
                        valid += got
                        if (bufStart + valid >= fileSize) bufEof = true
                        bytesSinceHeartbeat += got
                    }
                    ringLock.notifyAll()
                }
                val now = System.currentTimeMillis()
                if (now - lastHeartbeat > 10_000) {
                    val mbps = bytesSinceHeartbeat / 1024.0 / 1024.0 / ((now - lastHeartbeat) / 1000.0)
                    Log.i(
                        TAG,
                        String.format(
                            "heartbeat: pos=%d bufStart=%d valid=%d ring=%dMB eof=%b fill=%.1f MB/s",
                            position, bufStart, valid, ringSize / (1024 * 1024), bufEof, mbps,
                        ),
                    )
                    lastHeartbeat = now
                    bytesSinceHeartbeat = 0
                }
            } else if (got == -1) {
                synchronized(ringLock) {
                    if (epoch == ringEpoch) {
                        bufEof = true
                    }
                    ringLock.notifyAll()
                }
            } else {
                // got == 0 or -2: read error or dead handle. Drop it so the next
                // iteration reconnects (NAS drop / server sleep), then back off
                // and retry — don't spin.
                synchronized(smbLock) {
                    if (!prefetchKilled && file != null) {
                        closeHandles()
                        fileKey = null
                        try {
                            connectLocked(
                                savedKey ?: return@synchronized,
                                savedCreds ?: return@synchronized,
                                savedShare ?: return@synchronized,
                                savedPath ?: return@synchronized,
                            )
                            Log.w(TAG, "reconnected after read error")
                        } catch (e: Exception) {
                            Log.w(TAG, "reconnect failed: ${e.message}")
                        }
                    }
                }
                try { Thread.sleep(500) } catch (_: InterruptedException) { return }
            }
        }
    }

    private fun closeHandles() {
        try { raf?.close() } catch (_: Exception) {}
        raf = null
        try { file?.close() } catch (_: Exception) {}
        file = null
    }

    private fun idx(abs: Long): Int = (abs % ringSize.toLong()).toInt()

    companion object {
        private const val TAG = "SmbDataSource"
        /// Read-ahead cache size (Nova uses 48 MB for network streams; we go up
        /// to 96 MB to absorb Wi-Fi jitter on 4K/REMUX). Allocated lazily and
        /// capped by file size — see ensureRingCapacity().
        private const val BUFFER_CAPACITY = 96 * 1024 * 1024
        /// Smallest ring we ever allocate (subtitle streams land here).
        private const val MIN_BUFFER_CAPACITY = 8 * 1024 * 1024
        /// Bytes pulled from SMB per read (jcifs-ng splits this into the
        /// server's negotiated MaxReadSize internally and decodes straight into
        /// the ring, no per-read allocation).
        private const val SMB_CHUNK = 4 * 1024 * 1024
    }
}
