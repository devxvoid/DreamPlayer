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
                if fd < 0 {
                    NSLog("[UpnpClient] socket() failed errno=%d", errno)
                    cont.resume(returning: locations); return
                }
                defer { close(fd) }

                var reuse: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                var broadcast: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
                // Multicast TTL 2 so SSDP reaches the LAN, and bind the
                // multicast egress to the Wi-Fi interface (needed on iOS
                // when the device has multiple interfaces; without it the
                // kernel may send via the wrong interface and get no reply).
                var ttl: Int32 = 2
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
                if let localIP = Self.localIPv4Address() {
                    var mif = in_addr()
                    inet_pton(AF_INET, localIP, &mif)
                    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &mif, socklen_t(MemoryLayout<in_addr>.size))
                    NSLog("[UpnpClient] local IP %@, multicast IF set", localIP)
                }

                let msg = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\nUSER-AGENT: DreamPlayer/1.0 UPnP/1.0\r\n\r\n".utf8)
                guard let dest = Self.sockaddrInet(target: "239.255.255.250", port: 1900) else {
                    cont.resume(returning: locations); return
                }

                let deadline = Date().addingTimeInterval(4.0)
                NSLog("[UpnpClient] SSDP M-SEARCH to 239.255.255.250:1900 (ST MediaServer:1)")
                // Send inside the deadline loop (like JellyfinDiscovery) so
                // lossy Wi-Fi still gets a probe each second, and use poll()
                // with 1 s timeout instead of blocking SO_RCVTIMEO.
                while Date() < deadline {
                    // (Re)send M-SEARCH each second
                    withUnsafePointer(to: dest) { addrPtr in
                        let sockAddr = addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                        msg.withUnsafeBytes { msgPtr in
                            _ = sendto(fd, msgPtr.baseAddress, msg.count, 0, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    // 1 s poll so we stay responsive to deadline and can resend
                    if poll(&pfd, 1, 1000) > 0 {
                        var buf = [UInt8](repeating: 0, count: 8192)
                        var src = sockaddr_in()
                        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                        let n = buf.withUnsafeMutableBytes { bufPtr in
                            withUnsafeMutablePointer(to: &src) { srcPtr in
                                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                                    recvfrom(fd, bufPtr.baseAddress, bufPtr.count, 0, sockPtr, &srcLen)
                                }
                            }
                        }
                        if n > 0 {
                            let resp = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                            if let loc = Self.headerValue(resp, name: "LOCATION") ?? Self.headerValue(resp, name: "Location") {
                                let trimmed = loc.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    locations.insert(trimmed)
                                    NSLog("[UpnpClient] LOCATION %@", trimmed)
                                }
                            }
                            // Drain any additional waiting packets without extra poll
                            while true {
                                var peek = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                                if poll(&peek, 1, 0) <= 0 { break }
                                var buf2 = [UInt8](repeating: 0, count: 8192)
                                var src2 = sockaddr_in()
                                var srcLen2 = socklen_t(MemoryLayout<sockaddr_in>.size)
                                let n2 = buf2.withUnsafeMutableBytes { b in
                                    withUnsafeMutablePointer(to: &src2) { s in
                                        s.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                                            recvfrom(fd, b.baseAddress, b.count, 0, sock, &srcLen2)
                                        }
                                    }
                                }
                                if n2 <= 0 { break }
                                let resp2 = String(bytes: buf2[0..<n2], encoding: .utf8) ?? ""
                                if let loc2 = Self.headerValue(resp2, name: "LOCATION") ?? Self.headerValue(resp2, name: "Location") {
                                    let t2 = loc2.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !t2.isEmpty {
                                        locations.insert(t2)
                                        NSLog("[UpnpClient] LOCATION %@", t2)
                                    }
                                }
                            }
                        }
                    }
                }
                NSLog("[UpnpClient] SSDP done %lu location(s)", UInt(locations.count))
                cont.resume(returning: locations)
            }
        }
    }

    private static func sockaddrInet(target: String, port: Int) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    private static func headerValue(_ resp: String, name: String) -> String? {
        for line in resp.components(separatedBy: "\r\n") {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            if k.caseInsensitiveCompare(name) == .orderedSame {
                return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// First `en*` interface IPv4 (Wi-Fi / Ethernet), copied from
    /// `JellyfinDiscovery.swift` so SSDP egress uses the right interface.
    private static func localIPv4Address() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let addr = current.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    return String(cString: host)
                }
            }
            ptr = current.pointee.ifa_next
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
