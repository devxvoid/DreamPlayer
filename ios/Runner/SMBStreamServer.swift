import AMSMB2
import Foundation
import Network

/// Minimal range-served local HTTP stream for SMB files. AVPlayer/AetherEngine
/// can only consume URLs, so SMB playback is bridged through a tiny loopback
/// HTTP server that maps `GET /<token>` (+ `Range` header) onto seekable
/// AMSMB2 reads — the same local-proxy shape as the CX Explorer handoff that
/// already works on Android.
protocol SMBStreamSource: AnyObject {
    func fileSize() async throws -> UInt64
    func read(at offset: UInt64, length: Int) async throws -> Data
    func close()
}

final class SMBStreamSourceImpl: SMBStreamSource {
    private let manager: SMB2Manager
    private let share: String
    private let filePath: String

    init(manager: SMB2Manager, share: String, filePath: String) {
        self.manager = manager
        self.share = share
        self.filePath = filePath
    }

    func fileSize() async throws -> UInt64 {
        let attrs = try await manager.attributesOfItem(atPath: filePath)
        if let size = attrs[.fileSizeKey] as? NSNumber {
            return size.uint64Value
        }
        if let size = attrs[.fileSizeKey] as? Int64 {
            return UInt64(size)
        }
        throw SMBStreamError.noSize
    }

    func read(at offset: UInt64, length: Int) async throws -> Data {
        let stream = manager.contents(atPath: filePath, range: offset..<(offset + UInt64(max(length, 0))))
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
        }
        return data
    }

    func close() {
        Task { try? await manager.disconnectShare() }
    }
}

enum SMBStreamError: LocalizedError {
    case noSize

    var errorDescription: String? {
        switch self {
        case .noSize: return "Could not read file size from SMB server"
        }
    }
}

final class SMBStreamServer: NSObject {
    static let shared = SMBStreamServer()

    private var listener: NWListener?
    private var sources: [String: SMBStreamSource] = [:]
    private var tokensByServer: [String: [String]] = [:]
    private let sourcesLock = NSLock()
    private(set) var port: UInt16 = 0

    private override init() { super.init() }

    var baseURL: URL? {
        port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)")
    }

    func start() throws {
        if listener != nil { return }
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: DispatchQueue(label: "dreamplayer.smb.server"))

        // The port is assigned asynchronously; wait briefly for it.
        var tries = 0
        while listener.port == nil && tries < 100 {
            usleep(10_000)
            tries += 1
        }
        guard let raw = listener.port?.rawValue else {
            listener.cancel()
            self.listener = nil
            throw SMBStreamError.noSize
        }
        port = raw
    }

    func register(serverId: String, token: String, source: SMBStreamSource) {
        sourcesLock.lock()
        sources[token] = source
        tokensByServer[serverId, default: []].append(token)
        sourcesLock.unlock()
    }

    func unregister(_ token: String) {
        sourcesLock.lock()
        let source = sources.removeValue(forKey: token)
        for (serverId, tokens) in tokensByServer {
            if tokens.contains(token) {
                tokensByServer[serverId] = tokens.filter { $0 != token }
            }
        }
        sourcesLock.unlock()
        source?.close()
    }

    /// Tears down every stream opened for a server (played playlist items).
    func unregisterAll(serverId: String) {
        sourcesLock.lock()
        let tokens = tokensByServer.removeValue(forKey: serverId) ?? []
        var closed: [SMBStreamSource] = []
        for token in tokens {
            if let source = sources.removeValue(forKey: token) {
                closed.append(source)
            }
        }
        sourcesLock.unlock()
        for source in closed {
            source.close()
        }
    }

    private func source(for token: String) -> SMBStreamSource? {
        sourcesLock.lock()
        defer { sourcesLock.unlock() }
        return sources[token]
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "dreamplayer.smb.conn")
        connection.start(queue: queue)
        receiveLoop(connection, queue: queue, box: DataBox())
    }

    private func receiveLoop(_ connection: NWConnection, queue: DispatchQueue, box: DataBox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let data {
                box.data.append(data)
            }
            if let headerEnd = box.data.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = box.data.subdata(in: box.data.startIndex..<headerEnd.upperBound)
                self.respond(connection, headerData: headerData)
            } else if error != nil || box.data.count >= 65536 {
                self.sendStatus(connection, status: 400, body: "Bad request")
            } else {
                self.receiveLoop(connection, queue: queue, box: box)
            }
        }
    }

    // MARK: - Request parsing / response

    private func respond(_ connection: NWConnection, headerData: Data) {
        guard let header = String(data: headerData, encoding: .utf8),
              let firstLine = header.components(separatedBy: "\r\n").first
        else {
            sendStatus(connection, status: 400, body: "Bad request")
            return
        }
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            sendStatus(connection, status: 400, body: "Bad request")
            return
        }
        var raw = parts[1]
        if let query = raw.firstIndex(of: "?") {
            raw = String(raw[..<query])
        }
        while raw.hasPrefix("/") {
            raw.removeFirst()
        }
        let token = raw.removingPercentEncoding ?? ""
        guard !token.isEmpty, let source = self.source(for: token) else {
            sendStatus(connection, status: 404, body: "Not found")
            return
        }

        var rangeRequested = false
        var rangeSpec: RangeSpec?

        for line in header.components(separatedBy: "\r\n").dropFirst() {
            let lowered = line.lowercased()
            if lowered.hasPrefix("range:") {
                let value = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
                if let parsed = Self.parseRange(value) {
                    rangeRequested = true
                    rangeSpec = parsed
                }
            }
        }

        do {
            let size = try runAsync { try await source.fileSize() }

            let lastIndex = size == 0 ? 0 : size - 1
            var startIndex: UInt64 = 0
            var endIndex: UInt64 = lastIndex
            if rangeRequested, let spec = rangeSpec {
                if let suffix = spec.suffix {
                    startIndex = size > suffix ? size - suffix : 0
                } else if let start = spec.start {
                    startIndex = start
                }
                if let end = spec.end {
                    endIndex = min(end, lastIndex)
                }
            }

            if rangeRequested, size == 0 || startIndex > endIndex {
                let headers = [
                    "HTTP/1.1 416 Range Not Satisfiable",
                    "Content-Range: bytes */\(size)",
                    "Content-Length: 0",
                    "Connection: close",
                ].joined(separator: "\r\n") + "\r\n\r\n"
                connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            let length = endIndex >= startIndex ? endIndex - startIndex + 1 : 0
            let statusLine = rangeRequested ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
            var headerLines = [
                statusLine,
                "Content-Type: application/octet-stream",
                "Accept-Ranges: bytes",
                "Content-Length: \(length)",
                "Connection: close",
            ]
            if rangeRequested {
                headerLines.append("Content-Range: bytes \(startIndex)-\(endIndex)/\(size)")
            }
            let headerText = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
            connection.send(content: Data(headerText.utf8), completion: .contentProcessed { [weak self] _ in
                self?.streamBody(connection, source: source, offset: startIndex, remaining: length)
            })
        } catch {
            sendStatus(connection, status: 500, body: "Stream error")
        }
    }

    private func streamBody(_ connection: NWConnection, source: SMBStreamSource, offset: UInt64, remaining: UInt64) {
        let chunkSize: UInt64 = 1024 * 1024
        let length = min(remaining, chunkSize)
        guard length > 0 else {
            connection.send(content: nil, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        do {
            let data = try runAsync { try await source.read(at: offset, length: Int(length)) }
            guard !data.isEmpty else {
                connection.cancel()
                return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.streamBody(connection, source: source, offset: offset + UInt64(data.count), remaining: remaining - UInt64(data.count))
            })
        } catch {
            connection.cancel()
        }
    }

    private func sendStatus(_ connection: NWConnection, status: Int, body: String) {
        let reason = status == 404 ? "Not Found" : (status == 416 ? "Range Not Satisfiable" : "Error")
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: text/plain",
            "Content-Length: \(body.count)",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        var payload = Data(headers.utf8)
        payload.append(Data(body.utf8))
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// `bytes=start-end`, `bytes=start-` and `bytes=-suffix`; nil when the
    /// header is malformed or multi-range.
    private static func parseRange(_ value: String) -> RangeSpec? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil }
        let pieces = spec.split(separator: "-", maxSplits: 1).map(String.init)
        guard !pieces.isEmpty else { return nil }
        if pieces.count == 1, let suffix = UInt64(pieces[0]) {
            return RangeSpec(suffix: suffix)
        }
        guard pieces.count == 2, let start = UInt64(pieces[0]), !pieces[1].isEmpty else {
            return nil
        }
        return RangeSpec(start: start, end: UInt64(pieces[1]))
    }

    /// Bridges an async AMSMB2 read to the synchronous connection queue.
    private func runAsync<T>(_ op: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, any Error>!
        Task {
            do { result = .success(try await op()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }
}

/// Parsed single HTTP range. All fields optional — nil means "not specified".
private struct RangeSpec {
    var start: UInt64?
    var end: UInt64?
    var suffix: UInt64?
}

/// Mutable accumulator for one connection's request head (escaping-closure
/// friendly — can't capture an `inout` parameter in the receive callback).
private final class DataBox {
    var data = Data()
}
