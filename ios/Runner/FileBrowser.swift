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

    /// Synthetic path of the virtual "Files" root. Tapping it opens the system
    /// document picker (the real Files-app home), so it is never listed — Dart
    /// routes it to `openFilesHome` via the `isFilesHome` flag.
    static let filesHomePath = "dreamplayer/files-home"

    /// Security-scoped bookmarks for videos imported into the library, keyed by
    /// their file path. The library re-resolves (and starts access on) a path
    /// via `resolveImportedPath` before playback so Files-app picks stay
    /// readable across launches.
    private static let importedKey = "dreamplayer.importedVideos"

    /// URLs currently resolved from bookmarks with an active security scope.
    private var activeSecurityScopedURLs: [URL] = []
    /// Every stored folder bookmark resolved to its CURRENT URL (id → URL),
    /// recomputed on each `resolveAllBookmarks()`. Resume keys for files inside
    /// a bookmarked folder are derived relative to this current mount point, so
    /// they stay stable even when the provider remounts at a different path.
    private var bookmarkRoots: [String: URL] = [:]
    private var pickerCompletion: FlutterResult?
    private var pickerMode: PickerMode = .folder

    private override init() { super.init() }

    /// What the currently presented system picker returns.
    private enum PickerMode {
        case folder, file
    }

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
        case "openFilesHome":
            presentFilePicker(result)
        case "resolveImportedPath":
            let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
            result(resolveImportedPath(path))
        case "resolvePath":
            let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
            result(resolvePath(path))
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

    /// Virtual "Files" root (opens the system Files-app home via the document
    /// picker) + the app's Documents folder + every bookmarked folder.
    private func storageRoots() -> [[String: Any]] {
        var roots: [[String: Any]] = [[
            "name": "Files",
            "path": Self.filesHomePath,
            "isDirectory": true,
            "size": 0,
            "isFilesHome": true,
        ]]
        roots.append(entryMap(documentsURL, isDirectory: true))
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
                files.append(entryMap(
                    entry,
                    isDirectory: false,
                    resumeKey: resumeKey(for: entry.path, roots: bookmarkRoots)
                ))
            }
        }

        dirs.sort { Self.name($0) < Self.name($1) }
        files.sort { Self.name($0) < Self.name($1) }
        return dirs + files
    }

    private func entryMap(_ url: URL, isDirectory: Bool, bookmarkId: String? = nil, resumeKey: String? = nil) -> [String: Any] {
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
        if let resumeKey {
            map["resumeKey"] = resumeKey
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
            guard let url = resolve(data),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            entries.append(entryMap(url, isDirectory: true, bookmarkId: id))
        }
        return entries
    }

    /// Resolves every stored bookmark and starts its security scope so its
    /// paths are readable this session.
    private func resolveAllBookmarks() {
        var roots: [String: URL] = [:]
        for (id, data) in loadBookmarks() {
            guard let url = resolve(data) else { continue }
            roots[id] = url
            startAccess(url)
        }
        bookmarkRoots = roots
    }

    /// Resolves a security-scoped bookmark. On iOS the security scope is baked
    /// into the bookmark data automatically (no `.withSecurityScope` option,
    /// which is macOS-only); access still has to be started explicitly.
    private func resolve(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
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
        if let url = resolve(data),
           let index = activeSecurityScopedURLs.firstIndex(of: url) {
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.remove(at: index)
        }
    }

    // MARK: - Folder picker

    private func presentFolderPicker(_ result: @escaping FlutterResult) {
        presentPicker(result, mode: .folder, contentTypes: [.folder])
    }

    /// Presents the system document picker (the Files-app home: iCloud Drive,
    /// On My iPad, Downloads, providers...). The picked video is imported
    /// (bookmarked for future sessions) and returned for playback.
    private func presentFilePicker(_ result: @escaping FlutterResult) {
        presentPicker(result, mode: .file, contentTypes: [.movie])
    }

    private func presentPicker(_ result: @escaping FlutterResult,
                               mode: PickerMode,
                               contentTypes: [UTType]) {
        guard pickerCompletion == nil else {
            result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
            return
        }
        guard let top = topViewController() else {
            result(FlutterError(code: "no_vc", message: "No view controller to present the picker", details: nil))
            return
        }
        pickerCompletion = result
        pickerMode = mode
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        top.present(picker, animated: true)
    }

    // MARK: - Imported videos

    /// Re-grants security-scoped access to an imported video's file path (the
    /// grant is remembered as a bookmark at import time). Called by the library
    /// before pushing the player.
    private func resolveImportedPath(_ path: String) -> Bool {
        guard let data = loadImported()[path], let url = resolve(data) else { return false }
        startAccess(url)
        return true
    }

    /// Re-grants security-scoped access to [path] whether it belongs to an
    /// imported video or lives inside a bookmarked folder (re-resolves the
    /// folder bookmark and starts its scope). Used when a continue-watching
    /// card is tapped, since the folder's scope is only kept while browsing.
    private func resolvePath(_ path: String) -> Bool {
        if resolveImportedPath(path) { return true }
        resolveAllBookmarks()
        for (_, url) in bookmarkRoots {
            if path == url.path || path.hasPrefix(url.path + "/") {
                startAccess(url)
                return true
            }
        }
        return false
    }

    /// Stable resume identity for a file inside a bookmarked folder:
    /// `folderbookmark:<bookmarkId>:<path relative to the current mount>`.
    /// The relative part is computed against the CURRENT (re-resolved) root
    /// path, so the key survives the provider remounting the share at a
    /// different location between launches. Files outside bookmarked folders
    /// get no key (their absolute path is used instead).
    private func resumeKey(for path: String, roots: [String: URL]) -> String? {
        for (id, root) in roots {
            let rootPath = root.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(path.dropFirst(rootPath.count))
            return "folderbookmark:\(id)\(rel)"
        }
        return nil
    }

    private func loadImported() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: Self.importedKey) as? [String: Data] ?? [:]
    }

    /// Remembers [url] as an imported video (keyed by path) so its security
    /// scope can be re-granted later via `resolveImportedPath`.
    private func importFile(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .minimalBookmark) else { return }
        var imported = loadImported()
        imported[url.path] = data
        saveImported(imported)
    }

    private func saveImported(_ imported: [String: Data]) {
        UserDefaults.standard.set(imported, forKey: Self.importedKey)
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
            completion(FlutterError(code: "no_file", message: "No file was selected", details: nil))
            return
        }
        startAccess(url)
        switch pickerMode {
        case .folder:
            let bookmarkId = UUID().uuidString
            if let data = try? url.bookmarkData(options: .minimalBookmark) {
                var bookmarks = loadBookmarks()
                bookmarks[bookmarkId] = data
                saveBookmarks(bookmarks)
            }
            completion(entryMap(url, isDirectory: true, bookmarkId: bookmarkId))
        case .file:
            // Import the picked video (bookmark it) so it stays readable across
            // launches and continue-watching card taps can re-grant its scope.
            importFile(url)
            completion(entryMap(url, isDirectory: false))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerCompletion?(nil)
        pickerCompletion = nil
    }
}
