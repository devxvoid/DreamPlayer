import Flutter
import Foundation
import Security
import SMBClient as SMBClientLib

/// iOS SMB browse client (channel `dreamplayer/smb`), mirroring `SMBClient.kt`.
///
/// Handles server persistence (Keychain passwords), SMB browsing (shares,
/// directories), connection testing, LAN subnet scan, and stream URL
/// generation. Each `openShare` establishes a dedicated `SMBClientLib`
/// connection; `closeShare` tears it down.
final class SMBChannel: NSObject {

    static let shared = SMBChannel()
    private static let channelName = "dreamplayer/smb"

    private static let serversKey = "dreamplayer.smbServers"
    private static let sharesKey = "dreamplayer.smbShares"
    private static let keychainService = "com.dreamplayer.app.smb"
    private static let keychainAccountPrefix = "password."

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
    ]

    private static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "smi",
    ]

    private static let commonShares = [
        "videos", "video", "movies", "movie", "tv", "tvshows", "series",
        "media", "downloads", "download", "public", "share", "shares",
        "shared", "files", "home", "homes", "music", "photos", "photo",
        "Documents", "Desktop",
    ]

    /// Live SMB connections keyed by server ID (populated by `openShare`,
    /// torn down by `closeShare` or when the player is disposed).
    private var liveConnections: [String: SMBClientLib] = [:]
    private var liveLock = NSLock()

    // MARK: - Channel

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "listServers":
            result(listServers())
        case "saveServer":
            result(saveServer(
                id: args?["id"] as? String,
                name: args?["name"] as? String ?? "",
                host: args?["host"] as? String ?? "",
                port: (args?["port"] as? NSNumber)?.intValue ?? 445,
                username: args?["username"] as? String ?? "",
                password: args?["password"] as? String ?? "",
                domain: args?["domain"] as? String ?? "",
                anonymous: args?["anonymous"] as? Bool ?? false
            ))
        case "deleteServer":
            if let id = args?["id"] as? String { deleteServer(id) }
            result(nil)
        case "testConnection":
            Task.detached { [weak self] in
                let r = await self?.testConnection(
                    host: args?["host"] as? String ?? "",
                    port: (args?["port"] as? NSNumber)?.intValue ?? 445,
                    username: args?["username"] as? String ?? "",
                    password: args?["password"] as? String ?? "",
                    anonymous: args?["anonymous"] as? Bool ?? false
                ) ?? ["ok": false, "error": "Connection failed"]
                self?.respond(result, r)
            }
        case "listShares":
            guard let id = args?["id"] as? String else {
                respond(result, FlutterError(code: "bad_args", message: "Missing id", details: nil))
                return
            }
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let shares = try await self.listShares(serverId: id)
                    self.respond(result, shares)
                } catch {
                    self.respond(result, FlutterError(code: "smb_error", message: error.localizedDescription, details: nil))
                }
            }
        case "addShare":
            let id = args?["id"] as? String ?? ""
            let share = args?["share"] as? String ?? ""
            result(addShare(serverId: id, shareName: share))
        case "listDirectory":
            guard let id = args?["id"] as? String else {
                respond(result, FlutterError(code: "bad_args", message: "Missing id", details: nil))
                return
            }
            let share = args?["share"] as? String ?? ""
            let path = args?["path"] as? String ?? ""
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let entries = try await self.listDirectory(serverId: id, share: share, path: path)
                    self.respond(result, entries)
                } catch {
                    self.respond(result, FlutterError(code: "smb_error", message: error.localizedDescription, details: nil))
                }
            }
        case "openShare":
            let id = args?["id"] as? String ?? ""
            let share = args?["share"] as? String ?? ""
            let path = args?["path"] as? String ?? ""
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let url = try await self.openShare(serverId: id, share: share, path: path)
                    self.respond(result, url)
                } catch {
                    self.respond(result, FlutterError(code: "smb_error", message: error.localizedDescription, details: nil))
                }
            }
        case "closeShare":
            let id = args?["id"] as? String ?? ""
            closeShare(serverId: id)
            result(nil)
        case "discoverServers":
            Task.detached { [weak self] in
                let hosts = self?.discoverServers() ?? []
                self?.respond(result, hosts)
            }
        case "checkServer":
            let host = args?["host"] as? String ?? ""
            let port = (args?["port"] as? NSNumber)?.intValue ?? 445
            Task.detached { [weak self] in
                let ok = self?.isPortOpen(host: host, port: port, timeoutMs: 1500) ?? false
                self?.respond(result, ok)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func respond(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    // MARK: - Server persistence

    private struct Server {
        let id: String
        let name: String
        let host: String
        let port: Int
        let username: String
        let password: String
        let domain: String
        let anonymous: Bool

        func toMap() -> [String: Any] {
            [
                "id": id,
                "name": name,
                "host": host,
                "port": port,
                "username": username,
                "domain": domain,
                "anonymous": anonymous,
                "hasPassword": !password.isEmpty,
            ]
        }
    }

    private func loadServersMeta() -> [String: [String: Any]] {
        UserDefaults.standard.dictionary(forKey: Self.serversKey) as? [String: [String: Any]] ?? [:]
    }

    private func saveServersMeta(_ servers: [String: [String: Any]]) {
        UserDefaults.standard.set(servers, forKey: Self.serversKey)
    }

    private func saveServer(
        id: String?,
        name: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        domain: String,
        anonymous: Bool
    ) -> [String: Any] {
        let serverId = id ?? UUID().uuidString
        var servers = loadServersMeta()
        servers[serverId] = [
            "name": name.isEmpty ? host : name,
            "host": host,
            "port": port,
            "username": username,
            "domain": domain,
            "anonymous": anonymous,
        ]
        saveServersMeta(servers)
        if !password.isEmpty {
            setPassword(password, for: serverId)
        } else if id == nil {
            setPassword("", for: serverId)
        }
        return serverById(serverId)?.toMap() ?? [:]
    }

    private func serverById(_ id: String) -> Server? {
        guard let meta = loadServersMeta()[id] else { return nil }
        return Server(
            id: id,
            name: meta["name"] as? String ?? "",
            host: meta["host"] as? String ?? "",
            port: meta["port"] as? Int ?? 445,
            username: meta["username"] as? String ?? "",
            password: getPassword(id),
            domain: meta["domain"] as? String ?? "",
            anonymous: meta["anonymous"] as? Bool ?? false
        )
    }

    private func listServers() -> [[String: Any]] {
        loadServersMeta().keys.sorted().compactMap { serverById($0)?.toMap() }
    }

    private func deleteServer(_ id: String) {
        var servers = loadServersMeta()
        servers.removeValue(forKey: id)
        saveServersMeta(servers)
        deletePassword(id)
    }

    // MARK: - Share persistence (manually added)

    private func savedShares(_ serverId: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "\(Self.sharesKey)_\(serverId)") ?? []
    }

    private func addShare(serverId: String, shareName: String) -> Bool {
        var shares = savedShares(serverId)
        let name = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !shares.contains(name) else { return false }
        shares.append(name)
        UserDefaults.standard.set(shares, forKey: "\(Self.sharesKey)_\(serverId)")
        return true
    }

    // MARK: - Keychain

    private func setPassword(_ password: String, for id: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func getPassword(_ id: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func deletePassword(_ id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccountPrefix + id,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - SMB protocol

    private func testConnection(
        host: String,
        port: Int,
        username: String,
        password: String,
        anonymous: Bool
    ) async -> [String: Any] {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return ["ok": false, "error": "Host is required"] }
        do {
            let client = try makeClient(host: h, port: port)
            if anonymous {
                try await client.login(username: nil, password: nil)
            } else {
                try await client.login(username: username, password: password)
            }
            // Probe well-known shares via treeConnect to verify connectivity.
            var reachable = false
            for name in Self.commonShares {
                do {
                    let _ = try await client.connectShare(name)
                    try await client.disconnectShare()
                    try await client.logoff()
                    return ["ok": true, "error": nil as String?]
                } catch {
                    // Share doesn't exist or access denied — keep probing.
                    reachable = true
                }
            }
            try? await client.logoff()
            // If we authenticated but no known share exists, still report OK
            // (the user can add a share manually).
            if reachable { return ["ok": true, "error": nil as String?] }
            return ["ok": false, "error": "No SMB response from \(h)"]
        } catch {
            let msg = friendlyError(error)
            return ["ok": false, "error": msg]
        }
    }

    private func listShares(serverId: String) async throws -> [[String: Any]] {
        guard let server = serverById(serverId) else { throw SMBChannelError.serverNotFound }
        let client = try makeClient(host: server.host, port: server.port)
        if server.anonymous {
            try await client.login()
        } else {
            try await client.login(username: server.username, password: server.password)
        }

        var names = Set(savedShares(serverId))
        // Probe well-known shares via treeConnect (SMB2 has no NetShareEnum).
        for name in Self.commonShares {
            do {
                let _ = try await client.connectShare(name)
                try await client.disconnectShare()
                names.insert(name)
            } catch {
                // not a disk share / no access — skip
            }
        }
        try await client.logoff()
        return names.sorted().map { name in
            [
                "name": name,
                "path": name,
                "isDirectory": true,
                "size": 0,
                "modified": 0,
            ] as [String: Any]
        }
    }

    private func listDirectory(serverId: String, share: String, path: String) async throws -> [[String: Any]] {
        guard let server = serverById(serverId) else { throw SMBChannelError.serverNotFound }
        let client = try makeClient(host: server.host, port: server.port)
        if server.anonymous {
            try await client.login()
        } else {
            try await client.login(username: server.username, password: server.password)
        }
        try await client.connectShare(share)

        let dirPath = path.isEmpty ? "" : "/\(path)"
        let items = try await client.listDirectory(path: dirPath)
        try await client.logoff()

        var dirs: [[String: Any]] = []
        var videos: [[String: Any]] = []
        var subtitles: [String: [String]] = [:] // baseName -> [relPath]

        for item in items {
            let name = item.name
            if name == "." || name == ".." { continue }
            let relPath = path.isEmpty ? name : "\(path)/\(name)"
            if item.isDirectory {
                dirs.append(entryMap(name: name, path: relPath, isDir: true, size: 0, modified: 0))
            } else if isVideo(name) {
                videos.append(entryMap(name: name, path: relPath, isDir: false, size: Int64(item.size), modified: 0))
            } else if isSubtitle(name) {
                let base = baseName(name).lowercased()
                subtitles[base, default: []].append(relPath)
            }
        }

        // Auto-pair subtitles with videos (best match first).
        var paired: [[String: Any]] = []
        for video in videos {
            let videoName = video["name"] as? String ?? ""
            let videoBase = baseName(videoName).lowercased()
            var entry = video
            if let match = findMatchingSubtitle(videoBase: videoBase, subtitles: subtitles) {
                entry["subtitlePath"] = match
            }
            paired.append(entry)
        }

        dirs.sort { ($0["name"] as? String ?? "").lowercased() < ($1["name"] as? String ?? "").lowercased() }
        paired.sort { ($0["name"] as? String ?? "").lowercased() < ($1["name"] as? String ?? "").lowercased() }
        return dirs + paired
    }

    /// Opens a file for streaming and returns an `smb://` URI. Establishes a
    /// dedicated connection stored for AvPlayerView to resolve.
    private func openShare(serverId: String, share: String, path: String) async throws -> String {
        guard let server = serverById(serverId) else { throw SMBChannelError.serverNotFound }
        let client = try makeClient(host: server.host, port: server.port)
        if server.anonymous {
            try await client.login()
        } else {
            try await client.login(username: server.username, password: server.password)
        }
        try await client.connectShare(share)

        // Verify the file is readable and get its size.
        let filePath = "/\(path)"
        let stat = try await client.fileStat(path: filePath)
        guard !stat.isDirectory else { throw SMBChannelError.invalidURL }

        // Tear down any previous connection for this server.
        liveLock.lock()
        if let old = liveConnections[serverId] {
            Task { try? await old.logoff() }
        }
        liveConnections[serverId] = client
        liveLock.unlock()

        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "smb://\(serverId)/\(share)/\(encodedPath)"
    }

    private func closeShare(serverId: String) {
        liveLock.lock()
        let client = liveConnections.removeValue(forKey: serverId)
        liveLock.unlock()
        if let client {
            Task { try? await client.logoff() }
        }
    }

    /// Resolves an `smb://` URI to a `ByteRangeSource` for the engine.
    /// Called by `AvPlayerView` on the player thread.
    func resolveStreamURL(_ urlString: String) async throws -> (source: SMBByteRangeSource, client: SMBClientLib) {
        guard let url = URL(string: urlString),
              url.scheme == "smb",
              let serverId = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.path.nilIfEmpty else {
            throw SMBChannelError.invalidURL
        }
        // path is "/<share>/<file path>" — split into share and file path.
        let pathComponents = path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        guard pathComponents.count >= 2 else { throw SMBChannelError.invalidURL }
        let share = String(pathComponents[0])
        let filePath = pathComponents.count >= 2 ? "/" + pathComponents[1...] .joined(separator: "/") : ""

        liveLock.lock()
        let existingClient = liveConnections[serverId]
        liveLock.unlock()

        if let client = existingClient {
            let stat = try await client.fileStat(path: filePath)
            let reader = client.fileReader(path: filePath)
            let source = SMBByteRangeSource(reader: reader, fileSize: Int64(stat.size))
            return (source, client)
        }

        // No pre-established connection — resolve from stored credentials.
        guard let server = serverById(serverId) else { throw SMBChannelError.serverNotFound }
        let client = try makeClient(host: server.host, port: server.port)
        if server.anonymous {
            try await client.login(username: nil, password: nil)
        } else {
            try await client.login(username: server.username, password: server.password)
        }
        try await client.connectShare(share)
        let stat = try await client.fileStat(path: filePath)
        let reader = client.fileReader(path: filePath)
        let source = SMBByteRangeSource(reader: reader, fileSize: Int64(stat.size))
        liveLock.lock()
        liveConnections[serverId] = client
        liveLock.unlock()
        return (source, client)
    }

    // MARK: - LAN discovery

    private func discoverServers() -> [[String: Any]] {
        guard let subnet = localSubnet() else { return [] }
        let queue = DispatchQueue(label: "smb.discover", attributes: .concurrent)
        let group = DispatchGroup()
        let found = NSLock()
        var results: [(ip: UInt32, hostname: String)] = []
        let ownIP = subnet.2

        var ip = subnet.0 + 1
        while ip < subnet.1 {
            if ip != ownIP {
                let candidate = ip
                group.enter()
                queue.async {
                    if self.isPortOpen(host: Self.uint32ToIP(candidate), port: 445, timeoutMs: 500) {
                        let hostname = Self.reverseDNS(Self.uint32ToIP(candidate)) ?? Self.uint32ToIP(candidate)
                        found.lock()
                        results.append((candidate, hostname))
                        found.unlock()
                    }
                    group.leave()
                }
            }
            ip += 1
        }
        group.wait()
        return results.sorted { $0.ip < $1.ip }.map { ["host": Self.uint32ToIP($0.ip), "hostname": $0.hostname] }
    }

    private func localSubnet() -> (network: UInt32, broadcast: UInt32, ownIP: UInt32)? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(445).bigEndian
        inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr)
        guard withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }) == 0 else { return nil }
        var localAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &localAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        let ipN = localAddr.sin_addr.s_addr
        let mask: UInt32 = 0x00FFFFFF
        let network = ipN & mask
        let broadcast = network | ~mask
        return (network, broadcast, ipN)
    }

    private func isPortOpen(host: String, port: Int, timeoutMs: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: (timeoutMs % 1000) * 1000)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    private static func reverseDNS(_ ip: String) -> String? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        var storage = sockaddr_in()
        storage.sin_addr = addr
        let hostBuf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(NI_MAXHOST))
        defer { hostBuf.deallocate() }
        return withUnsafePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                if getnameinfo(saPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                               hostBuf, socklen_t(NI_MAXHOST), nil, 0, 0) == 0 {
                    let name = String(cString: hostBuf)
                    return name == ip ? nil : name
                }
                return nil
            }
        }
    }

    private static func uint32ToIP(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    // MARK: - Helpers

    private func makeClient(host: String, port: Int) throws -> SMBClientLib {
        // kishikawakatsumi/SMBClient default port is 445; non-standard ports
        // would need the Session-level API — for now assume 445.
        return try SMBClientLib(host: host)
    }

    private func isVideo(_ name: String) -> Bool { hasExtension(name, Self.videoExtensions) }
    private func isSubtitle(_ name: String) -> Bool { hasExtension(name, Self.subtitleExtensions) }
    private func hasExtension(_ name: String, _ extensions: Set<String>) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.index(before: name.endIndex) else { return false }
        return extensions.contains(String(name[name.index(after: dot)...]).lowercased())
    }

    private func baseName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    private func findMatchingSubtitle(videoBase: String, subtitles: [String: [String]]) -> String? {
        if let exact = subtitles[videoBase]?.sorted().first { return exact }
        for (subBase, paths) in subtitles {
            if subBase.hasPrefix("\(videoBase).") { return paths.sorted().first }
        }
        return nil
    }

    private func entryMap(name: String, path: String, isDir: Bool, size: Int64, modified: Int64) -> [String: Any] {
        ["name": name, "path": path, "isDirectory": isDir, "size": size, "modified": modified]
    }

    private func friendlyError(_ error: Error) -> String {
        let desc = error.localizedDescription
        if desc.contains("timed out") || desc.contains("timedout") { return "Timed out connecting to the server." }
        if desc.contains("not found") || desc.contains("resolve") { return "Can't reach the host. Check the address and your network." }
        if desc.contains("refused") || desc.contains("connection") { return "Connection refused. Check the host, port, and that the server is running." }
        return desc
    }
}

// MARK: - Errors

private enum SMBChannelError: Error, LocalizedError {
    case serverNotFound
    case invalidURL
    var errorDescription: String? {
        switch self {
        case .serverNotFound: return "SMB server not found"
        case .invalidURL: return "Invalid SMB URL"
        }
    }
}

// MARK: - String helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
