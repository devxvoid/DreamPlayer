import AMSMB2
import Flutter
import Foundation
import Security

/// A saved server record. Passwords never cross to Dart — they live in the
/// Keychain keyed by `id`; Dart only sees `hasPassword`.
private struct SmbServerRecord: Codable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var domain: String
    var username: String
    var anonymous: Bool
    var hasPassword: Bool
}

private enum SMBError: LocalizedError {
    case unknownServer
    case initFailed(String)
    case serverNotRunning

    var errorDescription: String? {
        switch self {
        case .unknownServer: return "Unknown server"
        case .initFailed(let host): return "Could not set up SMB connection to \(host)"
        case .serverNotRunning: return "SMB stream server is not running"
        }
    }
}

/// iOS implementation of the `dreamplayer/smb` channel — the same contract as
/// the (removed) Android `SMBClient.kt`, so the Dart `SmbClient` wrapper is
/// shared. Playback is served through `SMBStreamServer` as a local
/// `http://127.0.0.1:<port>/stream/...` URL (`openShare`/`closeShare`),
/// which is what AetherEngine/AVPlayer consume — mirroring the CX Explorer
/// local-proxy handoff that already works on Android.
final class SMBClient: NSObject {
    static let shared = SMBClient()
    private static let channelName = "dreamplayer/smb"

    private static let keychainService = "com.dreamplayer.app.smb"
    private static let serversKey = "dreamplayer.smbServers"
    private static let sharesKey = "dreamplayer.smbShares"

    private let queue = DispatchQueue(label: "dreamplayer.smb")

    /// One connected manager per open share (playback). Keyed by server id;
    /// value remembers which share it is bound to so a different share on the
    /// same server reconnects.
    private var playbackManagers: [String: (manager: SMB2Manager, share: String)] = [:]
    private let managersLock = NSLock()

    private override init() { super.init() }

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    // MARK: - Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "listServers":
            queue.async { result(self.serverMaps()) }

        case "saveServer":
            queue.async {
                do {
                    result(try self.saveServer(args ?? [:]))
                } catch {
                    result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
                }
            }

        case "deleteServer":
            let id = args?["id"] as? String ?? ""
            queue.async {
                self.deleteServer(id: id)
                result(nil)
            }

        case "testConnection":
            queue.async {
                result(self.testConnection(args ?? [:]))
            }

        case "listShares":
            let id = args?["id"] as? String ?? ""
            queue.async {
                do {
                    result(try self.listShares(serverId: id))
                } catch {
                    result(FlutterError(code: "smb_error", message: error.localizedDescription, details: nil))
                }
            }

        case "addShare":
            let id = args?["id"] as? String ?? ""
            let share = (args?["share"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !share.isEmpty else {
                result(FlutterError(code: "bad_args", message: "Missing id or share", details: nil))
                return
            }
            self.addShare(serverId: id, share: share)
            result(true)

        case "listDirectory":
            let id = args?["id"] as? String ?? ""
            let share = args?["share"] as? String ?? ""
            let path = args?["path"] as? String ?? ""
            guard !id.isEmpty, !share.isEmpty else {
                result(FlutterError(code: "bad_args", message: "Missing id or share", details: nil))
                return
            }
            queue.async {
                do {
                    result(try self.listDirectory(serverId: id, share: share, path: path))
                } catch {
                    result(FlutterError(code: "smb_error", message: error.localizedDescription, details: nil))
                }
            }

        case "discoverServers":
            queue.async {
                result(self.discoverServers())
            }

        case "checkServer":
            let host = args?["host"] as? String ?? ""
            guard !host.isEmpty else {
                result(FlutterError(code: "bad_args", message: "Missing host", details: nil))
                return
            }
            let port = (args?["port"] as? NSNumber)?.intValue ?? 445
            queue.async {
                result(self.isPortOpen(host: host, port: port, timeout: 0.35))
            }

        case "openShare":
            let id = args?["id"] as? String ?? ""
            let share = args?["share"] as? String ?? ""
            let path = args?["path"] as? String ?? ""
            queue.async {
                do {
                    result(try self.openShare(serverId: id, share: share, path: path))
                } catch {
                    result(FlutterError(code: "smb_error", message: error.localizedDescription, details: nil))
                }
            }

        case "closeShare":
            let id = args?["id"] as? String ?? ""
            queue.async {
                self.closeShare(serverId: id)
                result(nil)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Server store

    private func loadRecords() -> [SmbServerRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.serversKey),
              let records = try? JSONDecoder().decode([SmbServerRecord].self, from: data)
        else { return [] }
        return records
    }

    private func saveRecords(_ records: [SmbServerRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
    }

    private func record(id: String) -> SmbServerRecord? {
        loadRecords().first { $0.id == id }
    }

    private func serverMap(_ r: SmbServerRecord) -> [String: Any] {
        [
            "id": r.id,
            "name": r.name,
            "host": r.host,
            "port": r.port,
            "username": r.username,
            "domain": r.domain,
            "anonymous": r.anonymous,
            "hasPassword": r.hasPassword,
        ]
    }

    private func serverMaps() -> [[String: Any]] {
        loadRecords().map(serverMap)
    }

    private func saveServer(_ args: [String: Any]) throws -> [String: Any] {
        let id = (args["id"] as? String) ?? UUID().uuidString
        let host = (args["host"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw SMBError.initFailed("missing host") }

        var record = record(id: id) ?? SmbServerRecord(
            id: id, name: "", host: host, port: 445,
            domain: "", username: "", anonymous: false, hasPassword: false
        )
        let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        record.name = name.isEmpty ? host : name
        record.host = host
        record.port = (args["port"] as? NSNumber)?.intValue ?? 445
        record.domain = (args["domain"] as? String) ?? ""
        record.username = (args["username"] as? String) ?? ""
        record.anonymous = args["anonymous"] as? Bool ?? false

        let password = args["password"] as? String
        if let password, !password.isEmpty {
            setPassword(password, for: record.id)
            record.hasPassword = true
        }

        var records = loadRecords()
        records.removeAll { $0.id == record.id }
        records.append(record)
        saveRecords(records)
        return serverMap(record)
    }

    private func deleteServer(id: String) {
        var records = loadRecords()
        records.removeAll { $0.id == id }
        saveRecords(records)
        deletePassword(for: id)
        deleteShares(for: id)
        closeShare(serverId: id)
    }

    // MARK: - Share name store (manual add-share for unusual names)

    private func savedShares(for serverId: String) -> Set<String> {
        let dict = UserDefaults.standard.dictionary(forKey: Self.sharesKey) as? [String: [String]] ?? [:]
        return Set(dict[serverId] ?? [])
    }

    private func addShare(serverId: String, share: String) {
        var dict = UserDefaults.standard.dictionary(forKey: Self.sharesKey) as? [String: [String]] ?? [:]
        var shares = Set(dict[serverId] ?? [])
        shares.insert(share)
        dict[serverId] = shares.sorted()
        UserDefaults.standard.set(dict, forKey: Self.sharesKey)
    }

    private func deleteShares(for serverId: String) {
        var dict = UserDefaults.standard.dictionary(forKey: Self.sharesKey) as? [String: [String]] ?? [:]
        dict.removeValue(forKey: serverId)
        UserDefaults.standard.set(dict, forKey: Self.sharesKey)
    }

    // MARK: - Keychain

    private func setPassword(_ password: String, for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private func password(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deletePassword(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - AMSMB2

    private func manager(for record: SmbServerRecord) -> SMB2Manager? {
        let hostPort = record.port == 445 ? record.host : "\(record.host):\(record.port)"
        guard let url = URL(string: "smb://\(hostPort)") else { return nil }
        let credential: URLCredential
        if record.anonymous {
            credential = URLCredential(user: "guest", password: "", persistence: .forSession)
        } else {
            credential = URLCredential(
                user: record.username, password: password(for: record.id) ?? "",
                persistence: .forSession
            )
        }
        let manager = SMB2Manager(url: url, domain: record.domain, credential: credential)
        manager?.timeout = 30
        return manager
    }

    /// Bridges an async AMSMB2 operation to the synchronous channel handler.
    /// Runs on `queue`, so blocking here only stalls other SMB calls.
    private func runAsync<T>(_ op: @Sendable @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, any Error>!
        Task {
            do { result = .success(try await op()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    /// Runs a body against a freshly connected share, then disconnects.
    private func withShare<T>(
        _ record: SmbServerRecord, share: String,
        _ body: @escaping (SMB2Manager) async throws -> T
    ) throws -> T {
        guard let manager = manager(for: record) else {
            throw SMBError.initFailed(record.host)
        }
        return try runAsync {
            try await manager.connectShare(name: share)
            return try await body(manager)
        }
    }

    private func testConnection(_ args: [String: Any]) -> [String: Any?] {
        let host = (args["host"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            return ["ok": false, "error": "Host is required"]
        }
        let port = (args["port"] as? NSNumber)?.intValue ?? 445
        let hostPort = port == 445 ? host : "\(host):\(port)"
        guard let url = URL(string: "smb://\(hostPort)"),
              let manager = SMB2Manager(url: url, domain: args["domain"] as? String ?? "",
                                        credential: URLCredential(
                                            user: args["anonymous"] as? Bool == true ? "guest" : (args["username"] as? String ?? ""),
                                            password: args["password"] as? String ?? "",
                                            persistence: .forSession
                                        ))
        else {
            return ["ok": false, "error": "Could not set up SMB connection to \(host)"]
        }
        manager.timeout = 10
        do {
            // listShares connects to IPC$ internally and fails on bad login,
            // which is exactly the reachability/auth probe we want.
            _ = try runAsync { try await manager.listShares() }
            return ["ok": true, "error": nil]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private func listShares(serverId: String) throws -> [[String: Any]] {
        guard let record = record(id: serverId) else { throw SMBError.unknownServer }
        guard let manager = manager(for: record) else { throw SMBError.initFailed(record.host) }
        manager.timeout = 10
        var names = savedShares(for: serverId)
        let shares = try runAsync { try await manager.listShares() }
        for share in shares { names.insert(share.name) }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map {
            ["name": $0, "path": $0, "isDirectory": true, "size": 0, "modified": 0]
        }
    }

    private func listDirectory(serverId: String, share: String, path: String) throws -> [[String: Any]] {
        guard let record = record(id: serverId) else { throw SMBError.unknownServer }
        return try withShare(record, share: share) { manager in
            let contents = try await manager.contentsOfDirectory(atPath: path)
            var dirs: [[String: Any]] = []
            var videos: [(base: String, entry: [String: Any])] = []
            var subtitles: [String: [String]] = [:]

            for item in contents {
                guard let name = item[.nameKey] as? String else { continue }
                let type = item[.fileResourceTypeKey] as? URLFileResourceType
                let isDir = type == .directory
                let rel = path.isEmpty ? name : "\(path)/\(name)"

                if isDir {
                    dirs.append(Self.entryMap(name: name, path: rel, isDir: true, size: 0, modified: 0))
                } else if Self.isVideo(name) {
                    let size = (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                    let modified: Int64
                    if let date = item[.contentModificationDateKey] as? Date {
                        modified = Int64(date.timeIntervalSince1970 * 1000)
                    } else {
                        modified = 0
                    }
                    videos.append((Self.baseName(name).lowercased(),
                                   Self.entryMap(name: name, path: rel, isDir: false, size: size, modified: modified)))
                } else if Self.isSubtitle(name) {
                    subtitles[Self.baseName(name).lowercased(), default: []].append(rel)
                }
            }

            var files = videos.map { base, entry in
                var e = entry
                if let match = Self.findMatchingSubtitle(videoBase: base, subtitles: subtitles) {
                    e["subtitlePath"] = match
                }
                return e
            }
            dirs.sort { Self.name($0) < Self.name($1) }
            files.sort { Self.name($0) < Self.name($1) }
            return dirs + files
        }
    }

    private static func entryMap(name: String, path: String, isDir: Bool, size: Int64, modified: Int64) -> [String: Any] {
        ["name": name, "path": path, "isDirectory": isDir, "size": size, "modified": modified]
    }

    private static func name(_ entry: [String: Any]) -> String {
        (entry["name"] as? String ?? "").lowercased()
    }

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
    ]
    private static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "smi", "sub"]

    private static func hasExtension(_ name: String, in set: Set<String>) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return set.contains(ext)
    }

    private static func isVideo(_ name: String) -> Bool { hasExtension(name, in: videoExtensions) }
    private static func isSubtitle(_ name: String) -> Bool { hasExtension(name, in: subtitleExtensions) }

    /// File name without its last extension (`Show.S01E01.eng.srt` ->
    /// `Show.S01E01.eng`).
    private static func baseName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// Best sibling subtitle for a video: exact base-name match first
    /// (`Show.mkv` -> `Show.srt`), else a language-tagged match
    /// (`Show.mkv` -> `Show.eng.srt`).
    private static func findMatchingSubtitle(videoBase: String, subtitles: [String: [String]]) -> String? {
        if let exact = subtitles[videoBase]?.sorted().first { return exact }
        var best: (length: Int, path: String)?
        for (subBase, paths) in subtitles where subBase.hasPrefix("\(videoBase).") {
            guard let path = paths.sorted().first else { continue }
            if best == nil || subBase.count > best!.length {
                best = (subBase.count, path)
            }
        }
        return best?.path
    }

    // MARK: - Playback stream

    private func openShare(serverId: String, share: String, path: String) throws -> String {
        guard let record = record(id: serverId) else { throw SMBError.unknownServer }
        try SMBStreamServer.shared.start()

        let manager: SMB2Manager
        managersLock.lock()
        if let existing = playbackManagers[serverId], existing.share == share {
            manager = existing.manager
        } else {
            if let old = playbackManagers.removeValue(forKey: serverId) {
                Task { try? await old.manager.disconnectShare() }
            }
            guard let created = self.manager(for: record) else {
                managersLock.unlock()
                throw SMBError.initFailed(record.host)
            }
            manager = created
            playbackManagers[serverId] = (manager, share)
        }
        managersLock.unlock()

        // Queued on AMSMB2's serial operation queue ahead of every read, so
        // the first range request is guaranteed to hit a connected share.
        Task { try? await manager.connectShare(name: share) }

        let source = SMBStreamSourceImpl(manager: manager, share: share, filePath: path)
        let token = UUID().uuidString
        SMBStreamServer.shared.register(serverId: serverId, token: token, source: source)
        guard let base = SMBStreamServer.shared.baseURL else {
            throw SMBError.serverNotRunning
        }
        return base.appendingPathComponent(token).absoluteString
    }

    private func closeShare(serverId: String) {
        SMBStreamServer.shared.unregisterAll(serverId: serverId)
        managersLock.lock()
        let existing = playbackManagers.removeValue(forKey: serverId)
        managersLock.unlock()
        if let existing {
            Task { try? await existing.manager.disconnectShare() }
        }
    }

    // MARK: - Reachability / discovery

    /// Non-blocking TCP connect probe (POSIX + poll), used for both
    /// `checkServer` and the LAN scan.
    private func isPortOpen(host: String, port: Int, timeout: TimeInterval) -> Bool {
        var hint = addrinfo()
        hint.ai_family = AF_UNSPEC
        hint.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hint, &res) == 0, let addr = res else { return false }
        defer { freeaddrinfo(res) }

        let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        if flags < 0 { return false }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let n = poll(&pfd, 1, Int32(timeout * 1000))
        if n <= 0 { return false }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    private func localIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }

        var result: String?
        var ptr = addrs
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let flags = Int32(ifa.ifa_flags)
                let up = flags & IFF_UP != 0
                let loopback = flags & IFF_LOOPBACK != 0
                if up && !loopback {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                                   socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        result = String(cString: host)
                        break
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return result
    }

    /// Concurrent 445 probe of the local /24, best-effort. Returns hostnames
    /// when reverse DNS answers (often empty on home networks).
    private func discoverServers() -> [[String: Any]] {
        guard let local = localIPv4() else { return [] }
        let comps = local.split(separator: ".")
        guard comps.count == 4, let last = Int(comps[3]) else { return [] }
        let prefix = comps[0...2].joined(separator: ".")

        let group = DispatchGroup()
        let pool = DispatchQueue(label: "dreamplayer.smb.discover", attributes: .concurrent)
        let foundLock = NSLock()
        var found: Set<String> = []

        for i in 1...254 where i != last {
            let host = "\(prefix).\(i)"
            group.enter()
            pool.async {
                if self.isPortOpen(host: host, port: 445, timeout: 0.3) {
                    foundLock.lock(); found.insert(host); foundLock.unlock()
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 3.5)

        return found.sorted().map { host in
            ["host": host, "hostname": Self.reverseName(host)]
        }
    }

    private static func reverseName(_ ip: String) -> String {
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = 0
        guard inet_pton(AF_INET, ip, &sin.sin_addr) == 1 else { return "" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafePointer(to: &sin) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, 0)
            }
        }
        guard rc == 0 else { return "" }
        return String(cString: host)
    }
}
