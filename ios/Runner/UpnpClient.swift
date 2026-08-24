import Flutter
import Foundation
import Network

/// iOS DLNA / UPnP ContentDirectory browser (channel `dreamplayer/upnp`),
/// mirroring `UpnpClient.kt` on Android.
///
/// Discovery is SSDP M-SEARCH to 239.255.255.250:1900; browsing is SOAP
/// ContentDirectory#Browse against the device's controlURL. HTTP is plain
/// URLSession — DLNA servers are LAN http.
final class UpnpClient: NSObject {

    static let shared = UpnpClient()
    private static let channelName = "dreamplayer/upnp"

    private let standardSession: URLSession
    private var serverCache: [String: UpnpServer] = [:]
    private let cacheQueue = DispatchQueue(label: "dreamplayer.upnp.cache")

    private struct UpnpServer {
        let id: String
        let name: String
        let location: String
        let controlUrl: String
        let baseUrl: String
        func toMap() -> [String: Any] { ["id": id, "name": name, "location": location, "controlUrl": controlUrl, "baseUrl": baseUrl] }
    }

    private override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        standardSession = URLSession(configuration: config)
        super.init()
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak shared] call, result in
            shared?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "discover":
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let servers = try await self.discover()
                    self.respond(result, servers.map { $0.toMap() })
                } catch {
                    self.respond(result, FlutterError(code: "upnp", message: error.localizedDescription, details: nil))
                }
            }
        case "browse":
            guard let args = call.arguments as? [String: Any],
                  let serverId = args["serverId"] as? String else {
                result(FlutterError(code: "bad_args", message: "Missing serverId", details: nil))
                return
            }
            let objectId = args["objectId"] as? String ?? "0"
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let entries = try await self.browse(serverId: serverId, objectId: objectId)
                    self.respond(result, entries)
                } catch {
                    self.respond(result, FlutterError(code: "upnp", message: error.localizedDescription, details: nil))
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func respond(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    // MARK: - Discovery (SSDP)

    private func discover() async throws -> [UpnpServer] {
        let locations = try await ssdpLocations()
        var servers: [String: UpnpServer] = [:]
        for loc in locations {
            if let srv = try? await fetchDeviceInfo(location: loc), !srv.controlUrl.isEmpty {
                servers[srv.id] = srv
            }
        }
        let list = Array(servers.values)
        cacheQueue.sync { serverCache = servers }
        return list
    }

    private func ssdpLocations() async throws -> Set<String> {
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var locations = Set<String>()
                let fd = socket(AF_INET, SOCK_DGRAM, 0)
                if fd < 0 { cont.resume(returning: locations); return }
                defer { close(fd) }

                var reuse: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                var broadcast: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: 3, tv_usec: 500000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\nUSER-AGENT: DreamPlayer/1.0 UPnP/1.0\r\n\r\n"
                guard let data = msg.data(using: .utf8) else { cont.resume(returning: locations); return }

                var dest = sockaddr_in()
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = UInt16(1900).bigEndian
                dest.sin_addr.s_addr = inet_addr("239.255.255.250")

                data.withUnsafeBytes { ptr in
                    _ = withUnsafePointer(to: &dest) { destPtr in
                        destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            sendto(fd, ptr.baseAddress, data.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                // Second send for lossy Wi-Fi
                data.withUnsafeBytes { ptr in
                    _ = withUnsafePointer(to: &dest) { destPtr in
                        destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            sendto(fd, ptr.baseAddress, data.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }

                let deadline = Date().addingTimeInterval(4.0)
                var buf = [UInt8](repeating: 0, count: 8192)
                while Date() < deadline {
                    var src = sockaddr_in()
                    var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = buf.withUnsafeMutableBytes { bufPtr in
                        withUnsafeMutablePointer(to: &src) { srcPtr in
                            srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                                recvfrom(fd, bufPtr.baseAddress, bufPtr.count, 0, sockPtr, &srcLen)
                            }
                        }
                    }
                    if n <= 0 { break }
                    let resp = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                    if let loc = headerValue(resp, name: "LOCATION") ?? headerValue(resp, name: "Location") {
                        let trimmed = loc.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { locations.insert(trimmed) }
                    }
                }
                cont.resume(returning: locations)
            }
        }
    }

    private func headerValue(_ resp: String, name: String) -> String? {
        for line in resp.components(separatedBy: "\r\n") {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            if k.caseInsensitiveCompare(name) == .orderedSame {
                return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func fetchDeviceInfo(location: String) async throws -> UpnpServer? {
        guard let url = URL(string: location) else { return nil }
        let (data, response) = try await standardSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        let baseUrl = "\(url.scheme ?? "http")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
        return parseDeviceXml(data: data, baseUrl: baseUrl, location: location)
    }

    private func parseDeviceXml(data: Data, baseUrl: String, location: String) -> UpnpServer? {
        let delegate = DeviceXmlParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        guard let control = delegate.controlURL, !control.isEmpty else { return nil }
        let resolved = resolveUrl(base: baseUrl, url: control)
        let id = delegate.udn.isEmpty ? location : delegate.udn
        let name = delegate.friendlyName.isEmpty ? (URL(string: location)?.host ?? location) : delegate.friendlyName
        return UpnpServer(id: id, name: name, location: location, controlUrl: resolved, baseUrl: baseUrl)
    }

    private func resolveUrl(base: String, url: String) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        if url.hasPrefix("/") { return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + url }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + url
    }

    // MARK: - Browse (SOAP)

    private func browse(serverId: String, objectId: String) async throws -> [[String: Any]] {
        let server: UpnpServer? = cacheQueue.sync { serverCache[serverId] }
        guard let server else { throw NSError(domain: "UpnpClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "DLNA server not found. Discover again."]) }
        let soap = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
            <ObjectID>\(objectId)</ObjectID>
            <BrowseFlag>BrowseDirectChildren</BrowseFlag>
            <Filter>*</Filter>
            <StartingIndex>0</StartingIndex>
            <RequestedCount>0</RequestedCount>
            <SortCriteria></SortCriteria>
            </u:Browse>
            </s:Body>
            </s:Envelope>
            """
        guard let controlURL = URL(string: server.controlUrl) else { throw URLError(.badURL) }
        var req = URLRequest(url: controlURL)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = soap.data(using: .utf8)

        let (data, response) = try await standardSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "UpnpClient", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "Browse HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        return parseBrowseResult(data: data)
    }

    private func parseBrowseResult(data: Data) -> [[String: Any]] {
        // Pull <Result> which holds escaped DIDL-Lite.
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        // Quick string scan for <Result>…</Result> to avoid a full SOAP parse.
        guard let start = xml.range(of: "<Result>"), let end = xml.range(of: "</Result>") else { return [] }
        let didlEscaped = String(xml[start.upperBound..<end.lowerBound])
        // XMLParser will decode entities (&lt; etc.) if we wrap it.
        let wrapper = "<wrapper>\(didlEscaped)</wrapper>"
        guard let didlData = wrapper.data(using: .utf8) else { return [] }
        // First decode via XMLParser to unescape.
        let unescaper = ResultUnescaper()
        let p1 = XMLParser(data: didlData)
        p1.delegate = unescaper
        p1.parse()
        let didl = unescaper.result.isEmpty ? didlEscaped : unescaper.result
        // Unescaped DIDL may still be entity-escaped twice; decode again if needed.
        let didlDecoded = didl.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        guard let didlData2 = didlDecoded.data(using: .utf8) else { return [] }
        return parseDidl(data: didlData2)
    }

    private func parseDidl(data: Data) -> [[String: Any]] {
        let delegate = DidlParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        // Sort folders first, then alphabetically.
        return delegate.entries.sorted { a, b in
            let da = a["isDirectory"] as? Bool ?? false
            let db = b["isDirectory"] as? Bool ?? false
            if da != db { return da && !db }
            return (a["name"] as? String ?? "").lowercased() < (b["name"] as? String ?? "").lowercased()
        }
    }
}

// MARK: - Device XML parser

private final class DeviceXmlParser: NSObject, XMLParserDelegate {
    var friendlyName = ""
    var udn = ""
    var controlURL: String?
    private var currentServiceType: String?
    private var currentControlURL: String?
    private var text = ""
    private var inDevice = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "device" { inDevice = true }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "friendlyName": if inDevice && friendlyName.isEmpty { friendlyName = value }
        case "UDN": if inDevice && udn.isEmpty { udn = value }
        case "serviceType": currentServiceType = value
        case "controlURL": currentControlURL = value
        case "service":
            if let t = currentServiceType, t.contains("ContentDirectory") {
                controlURL = currentControlURL
            }
            currentServiceType = nil; currentControlURL = nil
        default: break
        }
        text = ""
    }
}

// MARK: - Result unescaper (decodes &lt; etc. inside <Result>)

private final class ResultUnescaper: NSObject, XMLParserDelegate {
    var result = ""
    func parser(_ parser: XMLParser, foundCharacters string: String) { result += string }
}

// MARK: - DIDL-Lite parser

private final class DidlParser: NSObject, XMLParserDelegate {
    var entries: [[String: Any]] = []
    private var currentId: String?
    private var currentIsContainer = false
    private var currentTitle: String?
    private var currentRes: String?
    private var currentResSize: Int64 = 0
    private var currentProtocolInfo: String?
    private var currentClass: String?
    private var inContainer = false
    private var inItem = false
    private var text = ""
    private let videoExts: Set<String> = ["mkv","mp4","avi","mov","ts","m2ts","wmv","flv","mpg","mpeg","webm","m4v","3gp","divx","vob"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let local = elementName // with shouldProcessNamespaces=true, this is local name
        if local == "container" {
            flush()
            inContainer = true; inItem = false
            currentIsContainer = true
            currentId = attributeDict["id"]
            currentTitle = nil; currentRes = nil; currentClass = nil
        } else if local == "item" {
            flush()
            inItem = true; inContainer = false
            currentIsContainer = false
            currentId = attributeDict["id"]
            currentTitle = nil; currentRes = nil; currentClass = nil; currentResSize = 0
        } else if local == "res" {
            currentProtocolInfo = attributeDict["protocolInfo"]
            if let sz = attributeDict["size"], let v = Int64(sz) { currentResSize = v }
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "title": if !value.isEmpty { currentTitle = value }
        case "class": currentClass = value
        case "res": if !value.isEmpty { currentRes = value }
        case "container", "item":
            flushEntry()
            inContainer = false; inItem = false
            currentId = nil; currentTitle = nil; currentRes = nil; currentClass = nil
        default: break
        }
        text = ""
    }

    private func flush() {
        // Flush is just a guard for malformed nesting; actual emit on end tag.
    }

    private func flushEntry() {
        guard let id = currentId else { return }
        if inContainer || currentIsContainer {
            let name = currentTitle ?? id
            entries.append(["name": name, "id": id, "isDirectory": true, "url": NSNull(), "size": 0])
        } else if inItem {
            guard let url = currentRes, !url.isEmpty else { return }
            let isVideo = isVideoCandidate()
            if !isVideo { return }
            let name = currentTitle ?? URL(string: url)?.lastPathComponent ?? id
            entries.append(["name": name, "id": id, "isDirectory": false, "url": url, "size": currentResSize])
        }
    }

    private func isVideoCandidate() -> Bool {
        let pi = currentProtocolInfo?.lowercased() ?? ""
        if pi.contains("video") { return true }
        if currentClass?.lowercased().contains("videoitem") == true { return true }
        if pi.contains("audio") || pi.contains("image") { return false }
        if let url = currentRes, let ext = URL(string: url)?.pathExtension.lowercased(), videoExts.contains(ext) { return true }
        if !pi.isEmpty && !pi.contains("video") { return false }
        return true
    }
}
