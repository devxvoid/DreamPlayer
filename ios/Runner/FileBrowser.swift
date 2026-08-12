import Flutter
import Foundation
import UniformTypeIdentifiers
import UIKit

/// iOS implementation of the `dreamplayer/files` channel (same contract as
/// `FileBrowser.kt` on Android). iOS is sandboxed, so there is no whole-storage
/// browsing: the base root is the app's Documents directory (exposed via
/// `UIFileSharingEnabled`), and any other folder is accessed through the system
/// document picker (`pickFolder`). Picked folders are kept usable across
/// launches with security-scoped bookmarks stored in UserDefaults.
final class FileBrowser: NSObject {

    static let shared = FileBrowser()
    private static let channelName = "dreamplayer/files"

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
    ]

    private static let bookmarksKey = "dreamplayer.folderBookmarks"

    /// URLs currently resolved from bookmarks with an active security scope.
    private var activeSecurityScopedURLs: [URL] = []
    private var pickerCompletion: FlutterResult?

    private override init() { super.init() }

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    // MARK: - Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasAllFilesAccess":
            result(true)
        case "openAllFilesAccessSettings":
            result(nil)
        case "getStorageRoots":
            result(storageRoots())
        case "listDirectory":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "bad_args", message: "Missing path", details: nil))
                return
            }
            result(listDirectory(path))
        case "pickFolder":
            presentFolderPicker(result)
        case "removeBookmark":
            let bookmarkId = (call.arguments as? [String: Any])?["bookmarkId"] as? String
            if let bookmarkId {
                removeBookmark(bookmarkId)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Roots

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Documents folder + every bookmarked folder the user picked before.
    private func storageRoots() -> [[String: Any]] {
        var roots = [entryMap(documentsURL, isDirectory: true)]
        roots.append(contentsOf: resolvedBookmarkEntries())
        return roots
    }

    // MARK: - Listing

    private func listDirectory(_ path: String) -> [[String: Any]] {
        // Re-resolve bookmarks first so any security scope covering the listed
        // path is active (needed after an app restart).
        resolveAllBookmarks()
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [["error": "not_found", "path": path]]
        }

        var dirs: [[String: Any]] = []
        var files: [[String: Any]] = []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                dirs.append(entryMap(entry, isDirectory: true))
            } else if Self.isVideo(entry.lastPathComponent) {
                files.append(entryMap(entry, isDirectory: false))
            }
        }

        dirs.sort { name($0) < name($1) }
        files.sort { name($0) < name($1) }
        return dirs + files
    }

    private func entryMap(_ url: URL, isDirectory: Bool, bookmarkId: String? = nil) -> [String: Any] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var map: [String: Any] = [
            "name": url.lastPathComponent,
            "path": url.path,
            "isDirectory": isDirectory,
            "size": isDirectory ? 0 : size,
        ]
        if let bookmarkId {
            map["bookmarkId"] = bookmarkId
        }
        return map
    }

    private static func name(_ entry: [String: Any]) -> String {
        (entry["name"] as? String ?? "").lowercased()
    }

    private static func isVideo(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return videoExtensions.contains(ext)
    }

    // MARK: - Bookmarks

    private func loadBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
    }

    private func saveBookmarks(_ bookmarks: [String: Data]) {
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
    }

    private func resolvedBookmarkEntries() -> [[String: Any]] {
        resolveAllBookmarks()
        var entries: [[String: Any]] = []
        for (id, data) in loadBookmarks() {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            entries.append(entryMap(url, isDirectory: true, bookmarkId: id))
        }
        return entries
    }

    /// Resolves every stored bookmark and starts its security scope so its
    /// paths are readable this session.
    private func resolveAllBookmarks() {
        for (_, data) in loadBookmarks() {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else { continue }
            startAccess(url)
        }
    }

    private func startAccess(_ url: URL) {
        guard !activeSecurityScopedURLs.contains(url) else { return }
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.append(url)
        }
    }

    private func removeBookmark(_ bookmarkId: String) {
        var bookmarks = loadBookmarks()
        guard let data = bookmarks.removeValue(forKey: bookmarkId) else { return }
        saveBookmarks(bookmarks)
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: nil),
           let index = activeSecurityScopedURLs.firstIndex(of: url) {
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.remove(at: index)
        }
    }

    // MARK: - Folder picker

    private func presentFolderPicker(_ result: @escaping FlutterResult) {
        guard pickerCompletion == nil else {
            result(FlutterError(code: "busy", message: "A folder picker is already open", details: nil))
            return
        }
        guard let top = topViewController() else {
            result(FlutterError(code: "no_vc", message: "No view controller to present the picker", details: nil))
            return
        }
        pickerCompletion = result
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        top.present(picker, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        return topMost(from: root)
    }

    private func topMost(from viewController: UIViewController) -> UIViewController? {
        if let nav = viewController as? UINavigationController {
            return topMost(from: nav.visibleViewController ?? nav)
        }
        if let tab = viewController as? UITabBarController {
            return topMost(from: tab.selectedViewController ?? tab)
        }
        if let presented = viewController.presentedViewController {
            return topMost(from: presented)
        }
        return viewController
    }
}

// MARK: - UIDocumentPickerDelegate

extension FileBrowser: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let completion = pickerCompletion else { return }
        pickerCompletion = nil
        guard let url = urls.first else {
            completion(FlutterError(code: "no_file", message: "No folder was selected", details: nil))
            return
        }
        startAccess(url)
        let bookmarkId = UUID().uuidString
        if let data = try? url.bookmarkData(options: .minimalBookmark) {
            var bookmarks = loadBookmarks()
            bookmarks[bookmarkId] = data
            saveBookmarks(bookmarks)
        }
        completion(entryMap(url, isDirectory: true, bookmarkId: bookmarkId))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerCompletion?(nil)
        pickerCompletion = nil
    }
}
