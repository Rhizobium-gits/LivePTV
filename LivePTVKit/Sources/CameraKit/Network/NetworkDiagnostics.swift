import Foundation
import Network

/// 🐱 Local interface facts used to explain connection problems before even trying the camera.
public struct InterfaceAddress: Sendable, Equatable, Codable {
    public let name: String
    public let ipv4: String
    public let netmask: String

    /// 🐱 True when `host` is inside this interface's IPv4 subnet.
    public func contains(host: String) -> Bool {
        guard let a = IPv4Address(ipv4), let m = IPv4Address(netmask), let h = IPv4Address(host) else { return false }
        let ai = a.rawValue, mi = m.rawValue, hi = h.rawValue
        return (0..<4).allSatisfy { (ai[$0] & mi[$0]) == (hi[$0] & mi[$0]) }
    }
}

public enum NetworkDiagnostics {
    /// 🐱 IPv4 addresses of all up, non-loopback interfaces (getifaddrs).
    public static func ipv4Interfaces() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            result.append(InterfaceAddress(name: String(cString: ifa.pointee.ifa_name),
                                           ipv4: numericHost(addr), netmask: numericHost(mask)))
        }
        return result
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        return String(cString: buf)
    }

    /// 🐱 Snapshot of the current Wi-Fi path (interface names that Network.framework classifies as Wi-Fi).
    public static func currentWiFiInterfaceNames(timeout: Double = 1.0) async -> [String] {
        await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            let q = DispatchQueue(label: "liveptv.pathprobe")
            let flag = QueueConfinedFlag()
            monitor.pathUpdateHandler = { path in
                guard !flag.done else { return }
                flag.done = true
                let names = path.status == .satisfied ? path.availableInterfaces.filter { $0.type == .wifi }.map(\.name) : []
                monitor.cancel()
                c.resume(returning: names)
            }
            monitor.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) {
                guard !flag.done else { return }
                flag.done = true
                monitor.cancel()
                c.resume(returning: [])
            }
        }
    }

    public enum ProbeOutcome: Sendable, Equatable {
        case reachable(connectMilliseconds: Double)
        case refused
        case localNetworkDenied
        case timedOut(lastWaitingReason: String?)
        case failed(String)
    }

    /// 🐱 Plain TCP connect test, closed immediately. Distinguishes "nothing there" from "port closed" from
    /// 🐱 "iPadOS blocked us" (Local Network privacy).
    public static func probeTCP(host: String, port: UInt16, timeout: Double = 3, requireWiFi: Bool) async -> ProbeOutcome {
        await withCheckedContinuation { (c: CheckedContinuation<ProbeOutcome, Never>) in
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = Int(max(1, timeout.rounded(.up)))
            let params = NWParameters(tls: nil, tcp: tcp)
            if requireWiFi { params.requiredInterfaceType = .wifi }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
            let q = DispatchQueue(label: "liveptv.tcpprobe")
            let start = HostClock.now()
            let flag = QueueConfinedFlag()
            @Sendable func finish(_ r: ProbeOutcome) {
                guard !flag.done else { return }
                flag.done = true
                conn.stateUpdateHandler = nil
                conn.cancel()
                c.resume(returning: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.reachable(connectMilliseconds: (HostClock.now() - start) * 1000))
                case let .waiting(err):
                    flag.note = "\(err)"
                    if conn.currentPath?.unsatisfiedReason == .localNetworkDenied { finish(.localNetworkDenied) }
                    else if case let .posix(code) = err, code == .ECONNREFUSED { finish(.refused) }
                case let .failed(err):
                    if case let .posix(code) = err, code == .ECONNREFUSED { finish(.refused) }
                    else { finish(.failed("\(err)")) }
                default:
                    break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(.timedOut(lastWaitingReason: flag.note)) }
        }
    }

    /// 🐱 One line of the diagnostics checklist shown in the app / printed by ace-probe.
    public struct Step: Sendable, Identifiable, Equatable {
        public enum Status: String, Sendable { case pass, warn, fail, skipped }
        public let id = UUID()
        public let title: String
        public let status: Status
        public let detail: String

        public static func == (a: Step, b: Step) -> Bool { a.title == b.title && a.status == b.status && a.detail == b.detail }
    }

    /// 🐱 Wi-Fi present? Address in the camera's subnet? TCP port open? Each step explains itself.
    public static func checkPath(to host: String, port: UInt16, requireWiFi: Bool) async -> [Step] {
        var steps: [Step] = []
        let wifiNames = await currentWiFiInterfaceNames()
        let interfaces = ipv4Interfaces()
        if requireWiFi {
            steps.append(wifiNames.isEmpty
                ? Step(title: "Wi-Fi connected", status: .fail, detail: "No active Wi-Fi interface.")
                : Step(title: "Wi-Fi connected", status: .pass, detail: "Interface \(wifiNames.joined(separator: ", "))."))
        }
        let candidates = requireWiFi ? interfaces.filter { wifiNames.contains($0.name) } : interfaces
        if let match = candidates.first(where: { $0.contains(host: host) }) {
            steps.append(Step(title: "Camera subnet", status: .pass,
                              detail: "\(match.name) has \(match.ipv4)/\(match.netmask), same subnet as \(host)."))
        } else {
            let addrs = candidates.map { "\($0.name) \($0.ipv4)" }.joined(separator: ", ")
            steps.append(Step(title: "Camera subnet", status: requireWiFi ? .fail : .warn,
                              detail: "No interface in the subnet of \(host). Current: \(addrs.isEmpty ? "none" : addrs). Join the camera's Wi-Fi network."))
        }
        switch await probeTCP(host: host, port: port, timeout: 3, requireWiFi: requireWiFi) {
        case let .reachable(ms):
            steps.append(Step(title: "Camera port \(port)", status: .pass, detail: String(format: "TCP connect in %.0f ms.", ms)))
        case .refused:
            steps.append(Step(title: "Camera port \(port)", status: .fail, detail: "Connection refused: the camera is there but its control service is closed."))
        case .localNetworkDenied:
            steps.append(Step(title: "Camera port \(port)", status: .fail, detail: "Blocked by Local Network privacy. Enable it in Settings > Privacy & Security > Local Network."))
        case let .timedOut(reason):
            steps.append(Step(title: "Camera port \(port)", status: .fail, detail: "No answer within 3 s\(reason.map { " (\($0))" } ?? "")."))
        case let .failed(why):
            steps.append(Step(title: "Camera port \(port)", status: .fail, detail: why))
        }
        return steps
    }
}

/// 🐱 Mutable state shared by callbacks that all run on one serial queue (so no lock is needed).
private final class QueueConfinedFlag: @unchecked Sendable {
    var done = false
    var note: String?
}
