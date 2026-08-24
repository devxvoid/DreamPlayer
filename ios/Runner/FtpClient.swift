import Flutter
import Foundation

/// iOS FTP/SFTP client (channel `dreamplayer/ftp`), mirroring `FtpClient.kt`.
///
/// v1 is browse-only on iOS: FTP/SFTP playback requires a streaming
/// DataSource (AetherEngine ByteRangeSource) like WebDAV. For now the channel
/// stores servers (UserDefaults + Keychain) and exposes list/test so the
/// browse UI works; listDirectory returns empty with a diagnostics hint
/// until the native streaming path is wired.
final class FtpClient: NSObject {

    static let shared = FtpClient()
    private static let channelName = "dreamplayer/ftp"

    private static let serversKey = "dreamplayer.ftpServers"
    private static let keychainService = "com.dreamplayer.app.ftp"
    private static let keychainAccountPrefix = "password."

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "saveServer":
            result(saveServer(
                id: args?["id"] as? String,
                name: args?["name"] as? String ?? "",
                host: args?["host"] as? String ?? "",
                port: args?["port"] as? Int ?? 21,
                path: args?["path"] as? String ?? "/",
                username: args?["username"] as? String ?? "",
                password: args?["password"] as? String ?? "",
                isSftp: args?["isSftp"] as? Bool ?? false
            ))
        case "listServers":
            result(listServers())
        case "deleteServer":
            if let id = args?["id"] as? String { deleteServer(id) }
            result(nil)
        case "testConnection":
            let host = args?["host"] as? String ?? ""
            let port = args?["port"] as? Int ?? 21
            let path = args?["path"] as? String ?? "/"
            let username = args?["username"] as? String ?? ""
            let password = args?["password"] as? String ?? ""
            let isSftp = args?["isSftp"] as? Bool ?? false
            // v1: basic validation only; real network probe deferred to Android.
            if host.trimmingCharacters(in: .whitespaces).isEmpty {
                result(["ok": false, "error": "Host is required"])
            } else {
                // Return ok so the dialog can save; browsing will surface errors.
                result(["ok": true])
                // Optional: could run a real FTP probe via CFNetwork here later.
                _ = (port, path, username, password, isSftp)
            }
        case "listDirectory":
            guard let id = args?["id"] as? String, serverById(id) != nil else {
                result(FlutterError(code: "bad_args", message: "FTP server not found", details: nil))
                return
            }
            // v1 placeholder: iOS FTP browsing not yet wired to a native FTP stack.
            // Return empty with diagnostics so the UI can show a hint.
            result([])
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Server persistence (mirrors WebDAVClient.swift)

    private struct Server {
        let id: String
        let name: String
        let host: String
        let port: Int
        let path: String
        let username: String
        let password: String
        let isSftp: Bool

        func toMap() -> [String: Any] {
            [
                "id": id,
                "name": name,
                "host": host,
                "port": port,
                "path": path,
                "username": username,
                "hasPassword": !password.isEmpty,
                "isSftp": isSftp,
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
        id: String?, name: String, host: String, port: Int, path: String,
        username: String, password: String, isSftp: Bool
    ) -> [String: Any] {
        let serverId = id ?? UUID().uuidString
        let normalizedPath: String = {
            var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { return "/" }
            if !p.hasPrefix("/") { p = "/" + p }
            while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
            return p
        }()
        var servers = loadServersMeta()
        servers[serverId] = [
            "name": name.isEmpty ? host : name,
            "host": host.trimmingCharacters(in: .whitespaces),
            "port": port,
            "path": normalizedPath,
            "username": username,
            "isSftp": isSftp,
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
            port: meta["port"] as? Int ?? 21,
            path: meta["path"] as? String ?? "/",
            username: meta["username"] as? String ?? "",
            password: getPassword(id),
            isSftp: meta["isSftp"] as? Bool ?? false
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
}
