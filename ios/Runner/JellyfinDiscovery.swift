import Flutter
import Foundation

/// Registers the `dreamplayer/multicast` channel on iOS: the Jellyfin/Emby
/// UDP-7359 broadcast probe ("who is JellyfinServer?" → JSON responses with
/// Address/Name/Id). Mirrors `MulticastLockManager.kt` on Android. Plain UDP
/// broadcast needs no multicast entitlement; the local-network privacy prompt
/// is already covered by NSLocalNetworkUsageDescription in Info.plist.
enum JellyfinDiscovery {

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "dreamplayer/multicast",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "discoverJellyfin":
                result(discover())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func discover() -> [[String: Any]] {
        var results: [[String: Any]] = []
        guard let localAddress = localIPv4Address() else { return results }

        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return results }
        defer { close(socketFD) }

        var broadcastOn: Int32 = 1
        setsockopt(
            socketFD, SOL_SOCKET, SO_BROADCAST, &broadcastOn,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let message = Data("who is JellyfinServer?".utf8)
        var targets: [String] = ["255.255.255.255"]
        let subnetBroadcast = broadcastAddress(for: localAddress)
        if !subnetBroadcast.isEmpty {
            targets.append(subnetBroadcast)
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            for target in targets {
                guard let addr = sockaddrInet(target: target, port: 7359) else { continue }
                withUnsafePointer(to: addr) { addrPtr in
                    let sockAddr = addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                    message.withUnsafeBytes { msgPtr in
                        _ = sendto(
                            socketFD, msgPtr.baseAddress, message.count, 0, sockAddr,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }

            var timeout = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            if poll(&timeout, 1, 1000) > 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var src = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &src) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, &buffer, buffer.count, 0, $0, &srcLen)
                    }
                }
                if n > 0 {
                    parse(body: String(data: Data(buffer[0..<n]), encoding: .utf8) ?? "", into: &results)
                }
            }
        }
        return results
    }

    private static func parse(body: String, into results: inout [[String: Any]]) {
        guard
            let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let address = json["Address"] as? String,
            !address.isEmpty
        else { return }
        if results.contains(where: { ($0["address"] as? String) == address }) { return }
        let name = json["Name"] as? String ?? address
        results.append(["address": address, "name": name, "id": json["Id"] as? String ?? ""])
    }

    /// First `en*` interface IPv4 address (Wi-Fi / Ethernet).
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
                    getnameinfo(
                        current.pointee.ifa_addr,
                        socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
                    )
                    return String(cString: host)
                }
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }

    /// /24 subnet-directed broadcast for the given IPv4 (typical home LAN).
    private static func broadcastAddress(for ip: String) -> String {
        var inaddr = in_addr()
        guard inet_pton(AF_INET, ip, &inaddr) == 1 else { return "" }
        let net = inaddr.s_addr & UInt32(0xFFFFFF00).bigEndian
        var bc = net | UInt32(0x000000FF).bigEndian
        var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &bc, &out, socklen_t(INET_ADDRSTRLEN))
        return String(cString: out)
    }

    private static func sockaddrInet(target: String, port: Int) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { return nil }
        return addr
    }
}
