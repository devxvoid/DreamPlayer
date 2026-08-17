import Foundation
import AetherEngine
import AetherEngineSMB

/// Ring-buffer + multi-thread prefetch reader for SMB/WebDAV playback.
///
/// Ports the Android `SmbDataSource` design (4 parallel prefetch threads, each
/// with its own SMB handle / TCP connection) to iOS:
///
/// - **Ring buffer** (default 96 MiB) keeps data ahead of the read cursor.
/// - **4 prefetch tasks** each read different regions of the file simultaneously
///   via their own `ByteRangeSource`, then copy into the ring under lock (with
///   epoch check to prevent stale writes from killed/restarted tasks).
/// - **Out-of-order completion** merges chunks that land ahead of the contiguous
///   write frontier.
/// - `read()` serves from the ring; `seek()` within the ring is a cheap cursor
///   move; outside triggers a re-anchor.
///
/// Lifecycle: `cancel()` unblocks a pending read; `close()` stops prefetch
/// tasks and does NOT close the underlying sources (SMBClient owns their
/// lifetime).
final class BufferedSMBReader: IOReader, @unchecked Sendable {

    // ---- Configuration ----
    private let sources: [ByteRangeSource]
    private let ownsSources: Bool
    private let discProbe: Bool
    private let ringCapacity: Int
    private let chunkSize: Int

    // ---- Ring buffer (guarded by ringLock) ----
    private let ringLock = NSCondition()
    private var ring: UnsafeMutableRawPointer?
    private var ringSize = 0
    private var bufStart: Int64 = 0
    private var valid: Int64 = 0
    private var bufEof = false
    private var fileSize: Int64 = 0
    private var position: Int64 = 0
    private var nextWritePos: Int64 = 0
    private var pendingChunks: [Int64: Int] = [:]
    private var ringEpoch: UInt64 = 0

    // ---- Prefetch ----
    private var prefetchTasks: [Task<Void, Never>] = []
    private var prefetchGen: UInt64 = 0

    // ---- Read cancellation ----
    private var cancelEpoch: UInt64 = 0
    private var closed = false
    private var lastServed = 0

    // MARK: - Init

    /// Single-source convenience init (backward compat / makeIndependentReader).
    convenience init(
        source: ByteRangeSource,
        ownsSource: Bool = false,
        discImageProbeEnabled: Bool = false,
        chunkSize: Int = 4 * 1024 * 1024,
        windowGoal: Int = 32 * 1024 * 1024
    ) {
        self.init(
            sources: [source],
            ownsSource: ownsSource,
            discImageProbeEnabled: discImageProbeEnabled,
            chunkSize: chunkSize,
            ringCapacity: max(8 * 1024 * 1024, min(96 * 1024 * 1024, windowGoal * 3))
        )
    }

    /// Multi-source init for parallel prefetch.  `sources[0]` is the primary;
    /// additional sources give prefetch tasks independent TCP connections.
    init(
        sources: [ByteRangeSource],
        ownsSource: Bool = false,
        discImageProbeEnabled: Bool = false,
        chunkSize: Int = 4 * 1024 * 1024,
        ringCapacity: Int = 96 * 1024 * 1024
    ) {
        self.sources = sources
        self.ownsSources = ownsSource
        self.discProbe = discImageProbeEnabled
        self.chunkSize = chunkSize
        self.ringCapacity = ringCapacity
        fileSize = sources.first?.byteSize ?? 0
        allocateRing()
        startPrefetchers()
    }

    var discImageProbeEnabled: Bool { discProbe }

    deinit {
        if ownsSources { sources.forEach { $0.close() } }
        ring?.deallocate()
    }

    // MARK: - IOReader

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        let epoch = cancelEpoch
        ringLock.lock()

        // Wait for data if ring is empty.
        if availableLocked() == 0 && !bufEof && !closed {
            let deadline = Date().addingTimeInterval(10)
            var retriesLeft = 3
            while availableLocked() == 0 && !bufEof && !closed && cancelEpoch == epoch {
                if Date() >= deadline { break }
                ringLock.wait(until: deadline)
                // If prefetch died from a transient error, restart tasks.
                if availableLocked() == 0 && !bufEof && retriesLeft > 0 {
                    retriesLeft -= 1
                    ringLock.unlock()
                    startPrefetchers()
                    ringLock.lock()
                }
            }
        }

        let avail = availableLocked()
        guard avail > 0 else {
            ringLock.unlock()
            return bufEof ? 0 : -1
        }

        let toRead = min(Int(size), avail)
        let fromIdx = ringIdx(position)
        let first = min(toRead, ringSize - fromIdx)
        memcpy(buffer, ring!.advanced(by: fromIdx), first)
        if toRead > first {
            memcpy(buffer.advanced(by: first), ring!, toRead - first)
        }
        position += Int64(toRead)
        lastServed = toRead
        ringLock.notifyAll()
        ringLock.unlock()
        return Int32(toRead)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        ringLock.lock()
        defer { ringLock.unlock() }
        let candidate: Int64
        switch whence {
        case Int32(SEEK_SET): candidate = offset
        case Int32(SEEK_CUR): candidate = position + offset
        case Int32(SEEK_END): candidate = fileSize + offset
        case 65536:           return fileSize   // AVSEEK_SIZE
        default:              return -1
        }
        guard candidate >= 0 else { return -1 }
        let end = bufStart + valid
        if candidate < bufStart || candidate > end {
            reanchorLocked(at: candidate)
        }
        position = candidate
        ringLock.notifyAll()
        return position
    }

    func close() {
        ringLock.lock()
        closed = true
        ringLock.notifyAll()
        ringLock.unlock()
        for t in prefetchTasks { t.cancel() }
        prefetchTasks.removeAll()
    }

    func cancel() {
        ringLock.lock()
        cancelEpoch &+= 1
        ringLock.notifyAll()
        ringLock.unlock()
    }

    func makeIndependentReader() -> IOReader? {
        BufferedSMBReader(
            source: sources[0],
            ownsSource: false,
            discImageProbeEnabled: discProbe,
            chunkSize: chunkSize,
            ringCapacity: min(8 * 1024 * 1024, ringCapacity)
        )
    }

    // MARK: - Ring helpers (ringLock held)

    private func allocateRing() {
        let target = min(ringCapacity, max(8 * 1024 * 1024, Int(fileSize)))
        ring = UnsafeMutableRawPointer.allocate(byteCount: target, alignment: 16)
        ringSize = target
    }

    private func ringIdx(_ abs: Int64) -> Int {
        Int(abs % Int64(ringSize))
    }

    /// Contiguous valid bytes from `position`.
    private func availableLocked() -> Int {
        let end = bufStart + valid
        guard position >= bufStart, position < end else { return 0 }
        return Int(end - position)
    }

    private func reanchorLocked(at: Int64? = nil) {
        position = at ?? position
        bufStart = position
        valid = 0
        bufEof = false
        nextWritePos = position
        pendingChunks.removeAll(keepingCapacity: true)
        ringEpoch &+= 1
        ringLock.notifyAll()
        // Prefetch tasks detect the epoch change and self-adjust on next iteration.
    }

    // MARK: - Prefetch

    private static let PREFETCH_THREADS = 4

    private func startPrefetchers() {
        let gen = prefetchGen
        for i in 0..<Self.PREFETCH_THREADS {
            let src = i < sources.count ? sources[i] : sources[0]
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                self?.prefetchLoop(gen: gen, threadIdx: i, source: src)
            }
            prefetchTasks.append(task)
        }
    }

    private func prefetchLoop(gen: UInt64, threadIdx: Int, source: ByteRangeSource) {
        let tmpBuf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { tmpBuf.deallocate() }

        while !Task.isCancelled {
            var readAt: Int64 = 0
            var readLen = 0
            var epoch: UInt64 = 0

            // ---- Acquire a chunk to read ----
            ringLock.lock()
            while true {
                if gen != prefetchGen || closed {
                    ringLock.unlock()
                    return
                }
                if bufEof { ringLock.wait(); continue }

                // Trim consumed prefix.
                let consumed = (position - bufStart).clamped(to: 0...)
                if consumed > 0 {
                    bufStart = position
                    valid -= consumed
                    if valid < 0 { valid = 0 }
                    nextWritePos = max(nextWritePos, bufStart + valid)
                }

                let room = Int64(ringSize) - (nextWritePos - bufStart)
                if room >= Int64(chunkSize) {
                    readAt = nextWritePos
                    readLen = min(chunkSize, Int(room))
                    // Don't wrap inside a single chunk read.
                    readLen = min(readLen, ringSize - ringIdx(readAt))
                    nextWritePos = readAt + Int64(readLen)
                    epoch = ringEpoch
                    break
                }
                ringLock.wait()
            }
            ringLock.unlock()

            // ---- SMB read (outside lock — parallel with other threads) ----
            var got = -2
            let t0 = Date()
            do {
                let data = try await source.read(at: readAt, length: readLen)
                got = data.count
                // Copy from Data into tmpBuf.
                data.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        tmpBuf.copyMemory(from: base, byteCount: got)
                    }
                }
            } catch {
                got = -2
            }

            // ---- Copy into ring under lock ----
            if got > 0 {
                let ms = Date().timeIntervalSince(t0) * 1000
                if ms > 500 {
                    let mbps = Double(got) / 1024.0 / 1024.0 / max(ms / 1000.0, 0.001)
                    print("smb-prefetch t\(threadIdx) slow: \(got) bytes in \(String(format: "%.0f", ms))ms (\(String(format: "%.1f", mbps)) MB/s) at \(readAt)")
                }
                ringLock.lock()
                if epoch == ringEpoch && ring != nil {
                    var off = ringIdx(readAt)
                    var srcOff = 0
                    var remaining = got
                    while remaining > 0 {
                        let chunk = min(remaining, ringSize - off)
                        ring!.advanced(by: off).copyMemory(from: tmpBuf.advanced(by: srcOff), byteCount: chunk)
                        off = (off + chunk) % ringSize
                        srcOff += chunk
                        remaining -= chunk
                    }

                    // Advance valid contiguously.
                    if readAt == bufStart + valid {
                        valid += Int64(got)
                        // Merge pending out-of-order chunks.
                        while let first = pendingChunks.keys.min(),
                              first == bufStart + valid {
                            let entry = pendingChunks.removeValue(forKey: first)!
                            valid += Int64(entry)
                        }
                        if bufStart + valid >= fileSize { bufEof = true }
                    } else if readAt > bufStart + valid {
                        pendingChunks[readAt] = got
                    }
                }
                ringLock.notifyAll()
                ringLock.unlock()
            } else if got == -1 || (got == 0 && readLen > 0) {
                ringLock.lock()
                if epoch == ringEpoch { bufEof = true }
                ringLock.notifyAll()
                ringLock.unlock()
            } else {
                // Transient error: brief pause then retry.
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
