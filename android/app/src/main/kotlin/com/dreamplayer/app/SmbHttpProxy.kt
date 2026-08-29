package com.dreamplayer.app

import android.content.Context
import android.util.Log
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import jcifs.smb.SmbFile
import jcifs.smb.SmbRandomAccessFile
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

/**
 * Minimal loopback HTTP server that exposes an in-app SMB file over HTTP with
 * byte-range support. Purpose: give the libmpv fallback engine a URL it can
 * read (`http://127.0.0.1:<port>/<token>`) when the source is the in-app SMB
 * stack — jcifs-ng only talks to Media3-native DataSources, and libmpv cannot
 * read `smb://` directly.
 *
 * Android ships no `com.sun.net.httpserver`, so this is a tiny hand-rolled
 * HTTP/1.1 server: a daemon `ServerSocket` accept loop + one daemon thread per
 * connection. It supports GET/HEAD + single `Range` (`bytes=start-end`,
 * `bytes=start-`, `bytes=-suffix`); every connection is closed after its
 * response. Reads are serialized per file via a [ReentrantLock] because
 * `SmbRandomAccessFile` is not thread-safe.
 */
object SmbHttpProxy {

    private data class Handle(
        val token: String,
        val serverId: String,
        val share: String,
        val path: String,
    ) {
        @Volatile var size: Long = -1
        /// Set when the session is torn down; in-flight [serve] loops check it
        /// and abort instead of streaming into a dead socket.
        @Volatile var closed: Boolean = false

        /// Idle `SmbRandomAccessFile`s ready for reuse. One handle per in-flight
        /// request (so no shared seek position), but finished handles are parked
        /// here instead of closed — opening an SMB file costs a tree-connect +
        /// create round-trip each time, and mpv's probe fires ~15 range requests
        /// back to back, so re-opening every time is what made startup slow.
        val idle = ArrayDeque<SmbRandomAccessFile>()
        val idleLock = ReentrantLock()
    }

    private const val MAX_IDLE = 4

    private val handles = hashMapOf<String, Handle>()
    private var server: ServerSocket? = null
    @Volatile private var running = false
    private var port = -1
    @Volatile private var appContext: Context? = null

    private const val CHUNK = 1024 * 1024  // 1 MiB reads — reduces lock acquisitions

    /// Largest body served for ONE request. ffmpeg/mpv asks for open-ended
    /// ranges (`bytes=<seek>-`), i.e. "everything to EOF". Honouring that
    /// literally means one response streams hundreds of MB while holding its
    /// SMB handle — and when the user seeks, mpv abandons that connection but
    /// stops READING it rather than closing it, so our `out.write` blocks on a
    /// full socket buffer forever and the handle never comes back. The next
    /// seek then leases another handle, and after MAX_IDLE stalled streams the
    /// pool is exhausted and playback dies (observed: the same offset
    /// re-requested every ~12 s, never progressing).
    ///
    /// HTTP explicitly allows a server to satisfy a range request with a
    /// SHORTER range than asked for, as long as `Content-Range` and
    /// `Content-Length` agree. ffmpeg's HTTP demuxer handles that natively (it
    /// reads `Content-Range`'s total for the file size and re-issues a request
    /// for the next span), so capping the body bounds both the wasted work on
    /// an abandoned connection and how long a handle stays leased.
    private const val MAX_BODY = 16L * 1024 * 1024

    @Synchronized
    private fun ensureStarted(context: Context): Boolean {
        if (running) return true
        return try {
            appContext = context.applicationContext
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(java.net.InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 16)
            server = ss
            port = ss.localPort
            running = true
            thread(isDaemon = true, name = "smb-http-accept") {
                while (running) {
                    try {
                        val sock = ss.accept()
                        thread(isDaemon = true, name = "smb-http-conn") { serve(sock) }
                    } catch (_: IOException) {
                        break
                    }
                }
            }
            true
        } catch (_: Exception) {
            running = false
            false
        }
    }

    /// Starts serving [path] on [share] of server [serverId] and returns the
    /// HTTP URL a ffmpeg/mpv reader can open, or null when the file can't be
    /// opened (bad credentials / not found / server not reachable — the same
    /// conditions the Media3 SMB path would surface).
    @Synchronized
    fun start(context: Context, serverId: String, share: String, path: String): String? {
        if (!ensureStarted(context)) return null
        val token = UUID.randomUUID().toString().replace("-", "")
        val handle = Handle(token, serverId, share, path)
        // Probe once so failures surface here as a clear "couldn't open"
        // instead of a cryptic 500 deep in mpv's probe. The probe handle is
        // PARKED for reuse (not closed) so mpv's very first range request
        // doesn't pay another tree-connect + create round-trip.
        val probe = try {
            openRaf(handle, context).also {
                handle.size = it.length()
            }
        } catch (e: Exception) {
            Log.w("SmbHttpProxy", "open failed serverId=$serverId share=$share path=$path: $e")
            null
        }
        if (probe == null) return null
        handle.idleLock.withLock { handle.idle.addLast(probe) }
        handles[token] = handle
        val url = "http://127.0.0.1:$port/$token"
        Log.i("SmbHttpProxy", "serving serverId=$serverId share=$share path=$path at $url size=${handle.size}")
        return url
    }

    @Synchronized
    fun stop(token: String) {
        val handle = handles.remove(token) ?: return
        handle.closed = true
        closeIdle(handle)
    }

    @Synchronized
    fun stopAll() {
        for (h in handles.values) {
            h.closed = true
            closeIdle(h)
        }
        handles.clear()
    }

    private fun closeIdle(handle: Handle) {
        handle.idleLock.withLock {
            while (handle.idle.isNotEmpty()) {
                try {
                    handle.idle.removeFirst().close()
                } catch (_: IOException) {
                }
            }
        }
    }

    /// Leases an `SmbRandomAccessFile` for one request: an idle handle when one
    /// is parked, otherwise a fresh open. Handles are NEVER shared between
    /// concurrent requests — ffmpeg's HTTP demuxer fires many overlapping range
    /// requests and a shared handle means each request's `seek()` clobbers the
    /// others mid-read (garbage bytes → decoder starvation → ANR).
    private fun leaseRaf(handle: Handle, context: Context): SmbRandomAccessFile {
        handle.idleLock.withLock {
            while (handle.idle.isNotEmpty()) {
                val raf = handle.idle.removeFirst()
                // A parked handle can have gone stale (NAS dropped the session).
                try {
                    raf.length()
                    return raf
                } catch (_: Exception) {
                    try {
                        raf.close()
                    } catch (_: IOException) {
                    }
                }
            }
        }
        return openRaf(handle, context)
    }

    /// Parks a finished handle for reuse, or closes it when the pool is full or
    /// the session is gone.
    private fun releaseRaf(handle: Handle, raf: SmbRandomAccessFile) {
        if (!handle.closed) {
            val parked = handle.idleLock.withLock {
                if (handle.idle.size < MAX_IDLE) {
                    handle.idle.addLast(raf)
                    true
                } else {
                    false
                }
            }
            if (parked) return
        }
        try {
            raf.close()
        } catch (_: IOException) {
        }
    }

    private fun openRaf(handle: Handle, context: Context): SmbRandomAccessFile {
        val creds = SmbStore.resolve(context, handle.serverId)
            ?: throw IOException("Unknown SMB server ${handle.serverId}")
        val base = "smb://${creds.host}:${creds.port}/${handle.share}"
        val url = if (handle.path.isEmpty()) base else "$base/${handle.path}"
        return SmbRandomAccessFile(SmbFile(url, creds.context()), "r")
    }

    private fun serve(sock: Socket) {
        try {
            sock.soTimeout = 180_000
            val input = BufferedInputStream(sock.getInputStream(), 8192)
            val requestLine = readLine(input)
            if (requestLine == null || requestLine.isEmpty()) return
            val parts = requestLine.split(" ")
            if (parts.size < 2) return
            val method = parts[0].uppercase()
            val target = parts[1]
            if (method != "GET" && method != "HEAD") {
                respondStatus(sock, "405 Method Not Allowed")
                return
            }
            var rangeHeader: String? = null
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                val lower = line.lowercase()
                if (lower.startsWith("range:")) {
                    rangeHeader = line.substringAfter(':').trim()
                }
            }
            Log.i("SmbHttpProxy", "req $method $target range=$rangeHeader")
            val token = target.trim('/').substringBefore('?')
            val handle = synchronized(handles) { handles[token] }
            if (handle == null) {
                respondStatus(sock, "404 Not Found")
                return
            }
            val context = appContext ?: return
            // Lease a handle for this request — reused from the idle pool when
            // available, so mpv's burst of probe range requests doesn't pay an
            // SMB open per request.
            val raf = try {
                leaseRaf(handle, context)
            } catch (_: Exception) {
                respondStatus(sock, "404 Not Found")
                return
            }
            try {
                streamResponse(sock, handle, raf, method, rangeHeader)
            } finally {
                releaseRaf(handle, raf)
            }
        } catch (_: Exception) {
            // Connection-level failures (client closed early) are not errors.
        } finally {
            try {
                sock.close()
            } catch (_: IOException) {
            }
        }
    }

    private fun streamResponse(
        sock: Socket,
        handle: Handle,
        raf: SmbRandomAccessFile,
        method: String,
        rangeHeader: String?,
    ) {
        val total = handle.size
        var start: Long
        var end: Long
        var isRange = false
        if (rangeHeader != null) {
            val parsed = parseRange(rangeHeader, total)
            if (parsed == null) {
                respondStatus(sock, "416 Range Not Satisfiable")
                return
            }
            start = parsed.first
            end = parsed.second
            isRange = true
        } else {
            start = 0
            end = total - 1
        }
        if (total < 0) {
            respondStatus(sock, "404 Not Found")
            return
        }
        // Cap the body (see MAX_BODY): an abandoned open-ended stream would
        // otherwise pin its SMB handle until the socket write blocks forever.
        if (end - start + 1 > MAX_BODY) {
            end = start + MAX_BODY - 1
            isRange = true
        }
        val length = end - start + 1
        val status = if (isRange) "206 Partial Content" else "200 OK"
        val sb = StringBuilder(256)
        sb.append("HTTP/1.1 ").append(status).append("\r\n")
        sb.append("Content-Type: application/octet-stream\r\n")
        sb.append("Accept-Ranges: bytes\r\n")
        if (isRange) {
            sb.append("Content-Range: bytes ").append(start).append('-').append(end)
                .append('/').append(total).append("\r\n")
        }
        sb.append("Content-Length: ").append(length).append("\r\n")
        sb.append("Connection: close\r\n")
        sb.append("\r\n")
        val headerBytes = sb.toString().toByteArray(Charsets.US_ASCII)
        val out = sock.getOutputStream()
        out.write(headerBytes)
        out.flush()
        if (method == "HEAD") return
        raf.seek(start)
        var remaining = length
        val buf = ByteArray(CHUNK)
        while (remaining > 0) {
            if (handle.closed) break
            val want = minOf(remaining, CHUNK.toLong()).toInt()
            val n = try {
                raf.read(buf, 0, want)
            } catch (_: IOException) {
                -1
            }
            if (n < 0) break
            try {
                out.write(buf, 0, n)
            } catch (_: IOException) {
                break
            }
            remaining -= n.toLong()
        }
        try {
            out.flush()
        } catch (_: IOException) {
        }
    }

    /// Returns (start, end) for a single byte range, or null when unsatisfiable.
    private fun parseRange(rangeHeader: String, total: Long): Pair<Long, Long>? {
        if (total <= 0) return null
        val spec = rangeHeader.removePrefix("bytes=").trim()
        if (!spec.matches(Regex("""\d*-\d*"""))) return null
        val dash = spec.indexOf('-')
        if (dash < 0) return null
        val sStr = spec.substring(0, dash).trim()
        val eStr = spec.substring(dash + 1).trim()
        val start: Long
        val end: Long
        if (sStr.isEmpty()) {
            // Suffix range: last N bytes.
            val n = eStr.toLongOrNull() ?: return null
            if (n <= 0) return null
            start = (total - n).coerceAtLeast(0)
            end = total - 1
        } else {
            start = sStr.toLongOrNull() ?: return null
            if (start >= total) return null
            end = if (eStr.isEmpty()) total - 1 else (eStr.toLongOrNull() ?: return null).coerceAtMost(total - 1)
        }
        if (end < start) return null
        return Pair(start, end)
    }

    private fun respondStatus(sock: Socket, status: String) {
        try {
            val body = "HTTP/1.1 $status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            val out = sock.getOutputStream()
            out.write(body.toByteArray(Charsets.US_ASCII))
            out.flush()
        } catch (_: IOException) {
        }
    }

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder(128)
        while (true) {
            val b = input.read()
            if (b < 0) return if (sb.isEmpty()) null else sb.toString()
            if (b == '\n'.code) break
            if (b != '\r'.code) sb.append(b.toChar())
        }
        return sb.toString()
    }
}