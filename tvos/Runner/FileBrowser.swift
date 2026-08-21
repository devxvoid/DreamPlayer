import Flutter
import Foundation
import UIKit

/// tvOS implementation of the `dreamplayer/files` channel. tvOS has no Files
/// app or document picker, so the only browsable root is the app's Documents
/// directory. No security-scoped bookmarks are needed — everything is in the
/// sandbox.
final class FileBrowser: NSObject {

    static let shared = FileBrowser()
    private static let channelName = "dreamplayer/files"

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
    ]

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
            DispatchQueue.global(qos: .userInitiated).async {
                let entries = Self.scanDirectory(path)
                DispatchQueue.main.async { result(entries) }
            }
        case "pickFolder", "pickLibraryFolder", "openFilesHome":
            // tvOS has no document picker — these are no-ops.
            result(nil)
        case "resolveImportedPath", "resolvePath":
            result(true)
        case "removeBookmark", "removeLibraryBookmark":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Roots

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func storageRoots() -> [[String: Any]] {
        [Self.entryMap(documentsURL, isDirectory: true)]
    }

    // MARK: - Listing

    private static func scanDirectory(_ path: String) -> [[String: Any]] {
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
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            var isDirectory = values?.isDirectory
            if isDirectory == nil {
                var flag: ObjCBool = false
                if FileManager.default.fileExists(atPath: entry.path, isDirectory: &flag) {
                    isDirectory = flag.boolValue
                }
            }
            guard let isDirectory else { continue }
            if isDirectory {
                dirs.append(entryMap(entry, isDirectory: true))
            } else if isVideo(entry.lastPathComponent) {
                files.append(entryMap(entry, isDirectory: false, size: values?.fileSize ?? 0))
            }
        }

        dirs.sort { name($0) < name($1) }
        files.sort { name($0) < name($1) }
        return dirs + files
    }

    private static func entryMap(_ url: URL, isDirectory: Bool, size: Int? = nil) -> [String: Any] {
        let fileSize = size ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return [
            "name": url.lastPathComponent,
            "path": url.path,
            "isDirectory": isDirectory,
            "size": isDirectory ? 0 : fileSize,
        ]
    }

    private static func name(_ entry: [String: Any]) -> String {
        (entry["name"] as? String ?? "").lowercased()
    }

    private static func isVideo(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return videoExtensions.contains(ext)
    }
}
