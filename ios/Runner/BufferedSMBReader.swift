import Foundation
import AetherEngine
import AetherEngineSMB

/// Read-ahead sliding-window wrapper around an `SMBConnection`, used as the
/// engine's custom `IOReader` for SMB playback.
///
/// Why this exists: `SMBIOReader` bridges FFmpeg reads straight to the network
/// — every demux read (256 KB AVIO buffer) is a synchronous SMB round-trip,
/// so a single Wi-Fi latency spike starves the engine's loopback HLS producer
/// and AVPlayer drops into `waitingToPlayAtSpecifiedRate` (the buffering
/// spinner). This is the same wall Android's jcifs-ng SMB hit (64 KB reads →
/// constant ring-buffer stalls); Nova's fix is a large ring buffer kept full
/// ahead of the cursor, which is what this reader implements for SMB.
///
/// A background prefetch task keeps a window (`windowGoal`, default 32 MiB)
/// of bytes buffered ahead of the read cursor: reads served from memory while
/// the next chunk is fetched from the NAS, so latency only bites on a seek or
/// a full window drain rather than on every 256 KB read.
///
/// Lifecycle mirrors SMBIOReader's contract: `cancel()` only unblocks a
/// pending read (never invalidates the reader — the engine reuses it across an
/// internal reload), `close()` stops the prefetch and does NOT close the
/// underlying `SMBConnection` (SMBClient owns its lifetime), and independent
/// readers share the same transport (SMBClient serialises request/response
/// pairs internally, so concurrent readers are safe).
final class BufferedSMBReader: IOReader, @unchecked Sendable {

    private let source: ByteRangeSource
    private let discProbe: Bool
    private let chunkSize: Int
    private let windowGoal: Int
    private let trimBatch: Int64

    // ---- Shared state, guarded by `cond`. ----
    private let cond = NSCondition()
    private var window = Data()
    private var windowStart: Int64 = 0     // file offset of window[0]
    private var position: Int64 = 0        // demux read cursor
    private var eof = false
    private var fetchFailed = false
    private var closed = false
    private var cancelEpoch: UInt64 = 0
    private var prefetchTask: Task<Void, Never>?

    init(
        source: ByteRangeSource,
        ownsSource: Bool = false,
        discImageProbeEnabled: Bool = false,
        chunkSize: Int = 4 * 1024 * 1024,
        windowGoal: Int = 32 * 1024 * 1024
    ) {
        self.source = source
        self.discProbe = discImageProbeEnabled
        self.chunkSize = chunkSize
        self.windowGoal = windowGoal
        self.trimBatch = Int64(4 * 1024 * 1024)
        startPrefetch()
    }

    var discImageProbeEnabled: Bool { discProbe }

    // MARK: - IOReader

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        // Snapshot the cancel epoch so a teardown cancel that lands mid-read
        // aborts THIS read only; the next read (engine reload reopen) is clean.
        let epoch = cancelEpoch
        cond.lock()
        if fetchFailed && windowEmpty() {
            cond.unlock()
            return -1
        }
        if !serveIfResident(into: buffer, max: Int(size)) {
            // Position is outside [windowStart, windowStart + count).
            let frontier = windowStart + Int64(window.count)
            if position < windowStart || position > frontier {
                // A genuine jump (backward past the window, or forward beyond
                // what is buffered): discard and re-anchor at the cursor. If
                // position == frontier we are simply caught up to the prefetch
                // (a fetch is in flight) — keep the window and wait for it.
                reanchorLocked()
            }
            waitForDataLocked(epoch: epoch)
            guard !fetchFailed && !windowEmpty() else {
                cond.unlock()
                return fetchFailed ? -1 : 0
            }
            _ = serveIfResident(into: buffer, max: Int(size))
        }
        cond.unlock()
        return Int32(lastServed)
    }

    private var lastServed = 0

    /// If `position` lies inside the window, copy up to `max` bytes into
    /// `buffer`, advance `position`, trim consumed prefix. Returns true when
    /// data was served; `lastServed` carries the byte count. Caller holds `cond`.
    private func serveIfResident(into buffer: UnsafeMutablePointer<UInt8>, max: Int) -> Bool {
        let rel = position - windowStart
        if rel >= 0, rel < Int64(window.count) {
            let want = min(max, window.count - Int(rel))
            window.withUnsafeBytes { raw in
                memcpy(buffer, raw.baseAddress!.advanced(by: Int(rel)), want)
            }
            position += Int64(want)
            lastServed = want
            trimIfNeededLocked()
            // Wake a parked prefetch that is waiting to top the window up.
            cond.broadcast()
            return true
        }
        lastServed = 0
        return false
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        cond.lock()
        defer { cond.unlock() }
        let candidate: Int64
        switch whence {
        case Int32(SEEK_SET): candidate = offset
        case Int32(SEEK_CUR): candidate = position + offset
        case Int32(SEEK_END): candidate = source.byteSize + offset
        case 65536:           return source.byteSize   // AVSEEK_SIZE
        default:              return -1
        }
        guard candidate >= 0 else { return -1 }
        // Within window: cheap cursor move. Outside: re-anchor.
        let rel = candidate - windowStart
        if rel < 0 || rel > Int64(window.count) {
            reanchorLocked(at: candidate)
        }
        position = candidate
        cond.broadcast()
        return position
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func cancel() {
        // Unblock a pending read so teardown doesn't hang. Like SMBIOReader,
        // this must NOT invalidate the reader: the engine reuses the same
        // reader across an internal reload, and only the read that observed
        // this cancel should abort.
        cond.lock()
        cancelEpoch &+= 1
        cond.broadcast()
        cond.unlock()
    }

    func makeIndependentReader() -> IOReader? {
        // Shares the SMBConnection; SMBClient serialises request/response
        // pairs, so the side demuxer / scrub reader can run concurrently.
        let clone = BufferedSMBReader(
            source: source,
            ownsSource: false,
            discImageProbeEnabled: discProbe,
            chunkSize: chunkSize,
            windowGoal: windowGoal
        )
        return clone
    }

    // MARK: - Window management (cond held)

    /// Discard the window and re-anchor it at `at` (default: current position).
    private func reanchorLocked(at: Int64? = nil) {
        window.removeAll(keepingCapacity: true)
        windowStart = at ?? position
        fetchFailed = false
        eof = false
        cond.broadcast()
    }

    private func windowEmpty() -> Bool {
        position - windowStart < 0 || position - windowStart >= Int64(window.count)
    }

    private func trimIfNeededLocked() {
        let consumed = position - windowStart
        if consumed >= trimBatch {
            let cut = Int(consumed)
            window.removeFirst(cut)
            windowStart += consumed
        }
    }

    /// Block until data is resident at `position`, EOF, fetch failure, or a
    /// cancel epoch change (teardown abort). Caller holds `cond`.
    private func waitForDataLocked(epoch: UInt64) {
        while !closed && cancelEpoch == epoch {
            if !windowEmpty() { return }
            if fetchFailed || eof { return }
            cond.wait()
        }
    }

    // MARK: - Prefetch

    private func startPrefetch() {
        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                var fetch: (from: Int64, want: Int)?
                self.cond.lock()
                if self.closed {
                    self.cond.unlock()
                    break
                }
                let frontier = self.windowStart + Int64(self.window.count)
                // Keep the window filled up to `windowGoal` ahead of the cursor.
                let goal = min(self.source.byteSize, self.position + Int64(self.windowGoal))
                if self.eof || frontier >= goal {
                    // Caught up / at EOF: park until a read or seek advances the cursor.
                    self.cond.wait()
                    self.cond.unlock()
                    continue
                }
                // A fresh kick (a serving read, a seek, a re-anchor) gets the
                // fetch another attempt — errors are transient, not fatal.
                self.fetchFailed = false
                let want = Int(min(Int64(self.chunkSize), goal - frontier))
                if want > 0 {
                    fetch = (frontier, want)
                }
                self.cond.unlock()

                guard let fetch else { continue }
                do {
                    let data = try await self.source.read(at: fetch.from, length: fetch.want)
                    self.cond.lock()
                    // Only append if the window wasn't re-anchored mid-fetch.
                    if !self.closed, self.windowStart + Int64(self.window.count) == fetch.from {
                        self.window.append(data)
                        if data.count < fetch.want { self.eof = true }
                        self.cond.broadcast()
                    }
                    self.cond.unlock()
                } catch {
                    self.cond.lock()
                    if !self.closed && !self.eof {
                        self.fetchFailed = true
                        // Park until the next read/seek kick. A read that hits
                        // the gap now returns -1 (demux error); a seek re-anchors
                        // and broadcasts to retry the fetch here.
                        self.cond.wait()
                    }
                    self.cond.broadcast()
                    self.cond.unlock()
                }
            }
        }
    }
}