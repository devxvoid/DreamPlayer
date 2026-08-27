import Flutter
import Foundation
import Security
import UIKit
import AetherEngineSMB
import AuthenticationServices

/// iOS Google Drive client (channel `dreamplayer/gdrive`), mirroring
/// `GDriveClient.kt`.
///
/// - Browsing is `GET https://www.googleapis.com/drive/v3/files?q=…`
///   with a Bearer header.
/// - Playback is a `ByteRangeSource` (`GDriveByteRangeSource`) that injects a
///   fresh Bearer token per read (so the 1h expiry never breaks a session),
///   wrapped by `BufferedSMBReader` like WebDAV.
/// - Persistence: `UserDefaults` for account list, Keychain
///   (`com.dreamplayer.app.gdrive`) for tokens.
///
/// OAuth: `ASWebAuthenticationSession` -> accounts.google.com/o/oauth2/v2/auth
/// -> `com.dreamplayer.app:/oauth2redirect` -> code exchange at
/// `oauth2.googleapis.com/token` -> `oauth2/v2/userinfo` for the email.
final class GDriveClient: NSObject {

    static let shared = GDriveClient()
    private static let channelName = "dreamplayer/gdrive"

    private static let accountsKey = "dreamplayer.gdriveAccounts"
    private static let keychainService = "com.dreamplayer.app.gdrive"

    private static let redirectUri = "com.dreamplayer.app:/oauth2redirect"
    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let scope = "https://www.googleapis.com/auth/drive.readonly"
    private static let userInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
    ]

    private var authSession: ASWebAuthenticationSession?
    private let session = URLSession(configuration: .ephemeral)

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
        case "listAccounts":
            result(listAccounts())
        case "signIn":
            let clientId = args?["clientId"] as? String ?? ""
            let clientSecret = args?["clientSecret"] as? String ?? ""
            if clientId.isEmpty {
                result(FlutterError(code: "gdrive_auth", message: "Missing GDRIVE_CLIENT_ID (set in .env)", details: nil))
                return
            }
            signIn(clientId: clientId, clientSecret: clientSecret, result: result)
        case "signOut":
            if let id = (args?["id"] as? String) ?? (args?["accountId"] as? String) {
                signOut(id: id)
            }
            result(nil)
        case "listDirectory":
            guard let accountId = args?["accountId"] as? String, !accountId.isEmpty else {
                result(FlutterError(code: "bad_args", message: "Missing accountId", details: nil))
                return
            }
            let folderId = args?["folderId"] as? String ?? "root"
            Task {
                do {
                    let entries = try await self.listDirectory(accountId: accountId, folderId: folderId)
                    await MainActor.run { result(entries) }
                } catch {
                    await MainActor.run { result(FlutterError(code: "gdrive", message: self.friendlyError(error), details: nil)) }
                }
            }
        case "authorizationHeader":
            guard let accountId = (args?["accountId"] as? String) ?? (args?["id"] as? String), !accountId.isEmpty else {
                result(FlutterError(code: "bad_args", message: "Missing accountId", details: nil))
                return
            }
            Task {
                do {
                    let token = try await self.getFreshAccessToken(accountId: accountId)
                    await MainActor.run { result("Bearer \(token)") }
                } catch {
                    await MainActor.run { result(FlutterError(code: "gdrive", message: self.friendlyError(error), details: nil)) }
                }
            }
        case "getFreshAccessToken":
            guard let accountId = (args?["accountId"] as? String) ?? (args?["id"] as? String), !accountId.isEmpty else {
                result(FlutterError(code: "bad_args", message: "Missing accountId", details: nil))
                return
            }
            Task {
                do {
                    let token = try await self.getFreshAccessToken(accountId: accountId)
                    await MainActor.run { result(token) }
                } catch {
                    await MainActor.run { result(FlutterError(code: "gdrive", message: self.friendlyError(error), details: nil)) }
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - OAuth

    private func signIn(clientId: String, clientSecret: String, result: @escaping FlutterResult) {
        let state = UUID().uuidString
        var comps = URLComponents(string: Self.authURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = comps.url else {
            result(FlutterError(code: "gdrive_auth", message: "Bad auth URL", details: nil))
            return
        }
        let callbackScheme = "com.dreamplayer.app"
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            guard let self else { return }
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                result(FlutterError(code: "gdrive_auth", message: "Sign-in cancelled", details: nil))
                return
            }
            if let error {
                result(FlutterError(code: "gdrive_auth", message: error.localizedDescription, details: nil))
                return
            }
            guard let url = callbackURL else {
                result(FlutterError(code: "gdrive_auth", message: "No callback URL", details: nil))
                return
            }
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value,
                  returnedState == state else {
                result(FlutterError(code: "gdrive_auth", message: "State mismatch", details: nil))
                return
            }
            if let err = comps.queryItems?.first(where: { $0.name == "error" })?.value {
                result(FlutterError(code: "gdrive_auth", message: err, details: nil))
                return
            }
            guard let code = comps.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                result(FlutterError(code: "gdrive_auth", message: "Missing code", details: nil))
                return
            }
            Task {
                do {
                    let account = try await self.exchangeCode(code: code, clientId: clientId, clientSecret: clientSecret)
                    await MainActor.run { result(account) }
                } catch {
                    await MainActor.run { result(FlutterError(code: "gdrive_auth", message: self.friendlyError(error), details: nil)) }
                }
            }
        }
        session.presentationContextProvider = self
        if #available(iOS 13.0, *) {
            // prefersEphemeralSession is 13+ but some Xcode SDKs miss it;
            // keep the session non-ephemeral by default.
        }
        authSession = session
        session.start()
    }

    private func exchangeCode(code: String, clientId: String, clientSecret: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: Self.tokenURL)!)
        req.httpMethod = "POST"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectUri),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]
        if !clientSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        var comps = URLComponents()
        comps.queryItems = items
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GDriveError(message: "Token exchange failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(body)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw GDriveError(message: "No access_token")
        }
        let refreshToken = json["refresh_token"] as? String ?? ""
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn).timeIntervalSince1970

        // Fetch user info for the account label.
        var email = "drive@google"
        var name = "Google Drive"
        do {
            var r = URLRequest(url: URL(string: Self.userInfoURL)!)
            r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (uData, uResp) = try await session.data(for: r)
            if let http2 = uResp as? HTTPURLResponse, (200...299).contains(http2.statusCode),
               let uj = try? JSONSerialization.jsonObject(with: uData) as? [String: Any] {
                email = (uj["email"] as? String) ?? email
                name = (uj["name"] as? String) ?? name
            }
        } catch { /* best-effort */ }

        let accountId = email.lowercased().isEmpty ? "gdrive_\(UUID().uuidString.lowercased())" : email.lowercased()
        setKeychain("accessToken.\(accountId)", accessToken)
        setKeychain("expiresAt.\(accountId)", "\(expiresAt)")
        setKeychain("clientId.\(accountId)", clientId)
        setKeychain("clientSecret.\(accountId)", clientSecret)
        if !refreshToken.isEmpty {
            setKeychain("refreshToken.\(accountId)", refreshToken)
        }
        setKeychain("email.\(accountId)", email)
        setKeychain("displayName.\(accountId)", name)
        saveAccount(id: accountId, email: email, displayName: name)
        return [
            "id": accountId,
            "email": email,
            "displayName": name,
            "hasRefreshToken": !(getKeychain("refreshToken.\(accountId)") ?? "").isEmpty,
        ]
    }

    // MARK: - Token refresh

    func getFreshAccessToken(accountId: String) async throws -> String {
        let now = Date().timeIntervalSince1970
        if let access = getKeychain("accessToken.\(accountId)"),
           let expStr = getKeychain("expiresAt.\(accountId)"),
           let exp = Double(expStr), now < exp - 60, !access.isEmpty {
            return access
        }
        guard let refresh = getKeychain("refreshToken.\(accountId)"), !refresh.isEmpty else {
            throw GDriveError(message: "No refresh token — sign in again")
        }
        guard let clientId = getKeychain("clientId.\(accountId)"), !clientId.isEmpty else {
            throw GDriveError(message: "Missing client ID — sign in again")
        }
        let clientSecret = getKeychain("clientSecret.\(accountId)") ?? ""
        var req = URLRequest(url: URL(string: Self.tokenURL)!)
        req.httpMethod = "POST"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        if !clientSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        var comps = URLComponents()
        comps.queryItems = items
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GDriveError(message: "Token refresh failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(body)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let newAccess = json["access_token"] as? String, !newAccess.isEmpty else {
            throw GDriveError(message: "No access_token in refresh")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let newExp = Date().addingTimeInterval(expiresIn).timeIntervalSince1970
        setKeychain("accessToken.\(accountId)", newAccess)
        setKeychain("expiresAt.\(accountId)", "\(newExp)")
        return newAccess
    }

    // MARK: - Listing

    func listDirectory(accountId: String, folderId: String) async throws -> [[String: Any]] {
        let token = try await getFreshAccessToken(accountId: accountId)
        let safe = folderId.replacingOccurrences(of: "'", with: "\\'")
        let q = "'\(safe)' in parents and trashed=false"
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime)"),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "orderBy", value: "folder,name"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GDriveError(message: "Drive list failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(body)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let files = json["files"] as? [[String: Any]] ?? []
        var entries: [[String: Any]] = []
        for f in files {
            guard let id = f["id"] as? String, !id.isEmpty,
                  let name = f["name"] as? String, !name.isEmpty else { continue }
            let mime = (f["mimeType"] as? String) ?? ""
            let isDir = mime == "application/vnd.google-apps.folder"
            let size: Int64
            if let s = f["size"] as? String, let v = Int64(s) { size = v }
            else if let n = f["size"] as? NSNumber { size = n.int64Value }
            else { size = 0 }
            if !isDir {
                let ext = (name as NSString).pathExtension.lowercased()
                if !ext.isEmpty && !Self.videoExtensions.contains(ext) { continue }
                if ext.isEmpty && !mime.hasPrefix("video/") && mime != "application/octet-stream" && !mime.isEmpty {
                    continue
                }
            }
            entries.append([
                "id": id,
                "name": name,
                "mimeType": mime,
                "isDirectory": isDir,
                "size": size,
            ])
        }
        entries.sort { a, b in
            let da = a["isDirectory"] as? Bool ?? false
            let db = b["isDirectory"] as? Bool ?? false
            if da != db { return da && !db }
            return (a["name"] as? String ?? "").lowercased() < (b["name"] as? String ?? "").lowercased()
        }
        return entries
    }

    // MARK: - Persistence

    private func listAccounts() -> [[String: Any]] {
        guard let raw = UserDefaults.standard.string(forKey: Self.accountsKey),
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.map { m in
            let id = (m["id"] as? String) ?? ""
            return [
                "id": id,
                "email": (m["email"] as? String) ?? "",
                "displayName": (m["displayName"] as? String) ?? "",
                "hasRefreshToken": !(getKeychain("refreshToken.\(id)") ?? "").isEmpty,
            ]
        }
    }

    private func saveAccount(id: String, email: String, displayName: String) {
        var existing: [[String: Any]] = []
        if let raw = UserDefaults.standard.string(forKey: Self.accountsKey),
           let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            existing = arr.filter { ($0["id"] as? String) != id }
        }
        existing.append(["id": id, "email": email, "displayName": displayName])
        if let data = try? JSONSerialization.data(withJSONObject: existing),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: Self.accountsKey)
        }
    }

    private func signOut(id: String) {
        var existing: [[String: Any]] = []
        if let raw = UserDefaults.standard.string(forKey: Self.accountsKey),
           let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            existing = arr.filter { ($0["id"] as? String) != id }
            if let d = try? JSONSerialization.data(withJSONObject: existing),
               let str = String(data: d, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: Self.accountsKey)
            }
        }
        for k in ["refreshToken", "accessToken", "expiresAt", "email", "displayName", "clientId", "clientSecret"] {
            deleteKeychain("\(k).\(id)")
        }
    }

    // MARK: - Keychain

    private func setKeychain(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func getKeychain(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychain(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - ByteRangeSource factory

    func makeByteRangeSource(fileId: String, accountId: String) throws -> GDriveByteRangeSource {
        try GDriveByteRangeSource(fileId: fileId, accountId: accountId)
    }

    private func friendlyError(_ error: Error) -> String {
        if let e = error as? GDriveError { return e.message }
        return error.localizedDescription
    }
}

private struct GDriveError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - ASWebAuthenticationSession presentation

extension GDriveClient: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // iOS 13+: find the key window.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            return window
        }
        return ASPresentationAnchor()
    }
}

// MARK: - ByteRangeSource for playback

/// Serves byte ranges of a Drive file (`alt=media`) with a fresh Bearer token
/// per read, wrapped by `BufferedSMBReader` in `AvPlayerView.open`.
final class GDriveByteRangeSource: ByteRangeSource, @unchecked Sendable {

    private let fileId: String
    private let accountId: String
    private let session: URLSession
    let size: Int64

    init(fileId: String, accountId: String) throws {
        self.fileId = fileId
        self.accountId = accountId
        self.session = URLSession(configuration: .ephemeral)
        var size: Int64 = -1
        var caught: Error?
        let sem = DispatchSemaphore(value: 0)
        Task {
            do { size = try await Self.probeSize(fileId: fileId, accountId: accountId) }
            catch { caught = error }
            sem.signal()
        }
        sem.wait()
        if let caught { throw caught }
        guard size > 0 else { throw GDriveError(message: "Could not determine file size") }
        self.size = size
    }

    var byteSize: Int64 { size }

    func read(at offset: Int64, length: Int) async throws -> Data {
        let token = try await GDriveClient.shared.getFreshAccessToken(accountId: accountId)
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        comps.queryItems = [URLQueryItem(name: "alt", value: "media")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func close() {}

    private static func probeSize(fileId: String, accountId: String) async throws -> Int64 {
        let token = try await GDriveClient.shared.getFreshAccessToken(accountId: accountId)
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        comps.queryItems = [URLQueryItem(name: "alt", value: "media")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let config = URLSessionConfiguration.ephemeral
        let sess = URLSession(configuration: config)
        let (_, resp) = try await sess.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 206,
           let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = Int64(range.components(separatedBy: "/").last ?? "") {
            return total
        }
        if let len = http.value(forHTTPHeaderField: "Content-Length"), let total = Int64(len) {
            return total
        }
        // Fallback: metadata fields=size
        var mComps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        mComps.queryItems = [URLQueryItem(name: "fields", value: "size")]
        var mReq = URLRequest(url: mComps.url!)
        mReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (mData, _) = try await sess.data(for: mReq)
        if let j = try? JSONSerialization.jsonObject(with: mData) as? [String: Any],
           let s = j["size"] as? String, let v = Int64(s) { return v }
        throw URLError(.badServerResponse)
    }
}
