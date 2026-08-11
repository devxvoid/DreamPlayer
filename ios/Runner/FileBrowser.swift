import Flutter
import Foundation

/// iOS implementation of the `dreamplayer/files` channel (same contract as
/// `FileBrowser.kt` on Android). iOS is sandboxed, so there is no whole-storage
/// browsing — the root is the app's Documents directory (exposed to the user
/// through the Files app via `UIFileSharingEnabled` /
/// `LSSupportsOpeningDocumentsInPlace`).
final class FileBrowser {

    private static let channelName = "dreamplayer/files"

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
        "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
    ]

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
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
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private static func storageRoots() -> [[String: Any]] {
        [
            [
                "name": "DreamPlayer",
                "path": documentsURL.path,
                "isDirectory": true,
                "size": 0,
            ]
        ]
    }

    private static func listDirectory(_ path: String) -> [[String: Any]] {
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
            } else if isVideo(entry.lastPathComponent) {
                files.append(entryMap(entry, isDirectory: false))
            }
        }

        dirs.sort { name($0) < name($1) }
        files.sort { name($0) < name($1) }
        return dirs + files
    }

    private static func entryMap(_ url: URL, isDirectory: Bool) -> [String: Any] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return [
            "name": url.lastPathComponent,
            "path": url.path,
            "isDirectory": isDirectory,
            "size": isDirectory ? 0 : size,
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
