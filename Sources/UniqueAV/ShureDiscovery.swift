import Foundation
import Network
import UniqueAVCore

/// Finds Shure devices the way Wireless Workbench does: Shure Discovery (SLP multicast on
/// 239.255.254.253:8427), which reaches every Shure device on the switch whatever its IP address,
/// plus a UHF-R broadcast on UDP 2202. Results are then checked on the control port and named.
struct FoundDevice: Identifiable, Equatable {
    var id: String { ip }
    var ip: String
    var kind: DeviceKind = .shure
    var sources: Set<String> = []       // "Shure Discovery", "UHF-R broadcast", "address scan"
    var hint = ""                       // SLP service string, e.g. "service:shure.ulxd4q://…"
    var model = ""
    var name = ""
    var reachable: Bool?                // nil = still checking
    var onMacNetwork = true
    var problem = ""
}

enum ShureDiscovery {
    /// Sends discovery requests on every interface and listens for `duration` seconds.
    /// `found` is called on the main queue for each new answer (ip, kind, hint).
    static func run(interfaces: [NetInterface], duration: TimeInterval = 5,
                    found: @escaping (String, DeviceKind, String) -> Void, done: @escaping () -> Void) {
        let own = Set(interfaces.map(\.ipv4))
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            slp(interfaces: interfaces, own: own, duration: duration, found: found)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            uhfrBroadcast(interfaces: interfaces, own: own, duration: duration, found: found)
            group.leave()
        }
        group.notify(queue: .main, execute: done)
    }

    // MARK: SLP (Shure Discovery)

    private static func slp(interfaces: [NetInterface], own: Set<String>, duration: TimeInterval,
                            found: @escaping (String, DeviceKind, String) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var yes: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, intSize)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, intSize)   // WWB may be listening on 8427 too
        // Listen on 8427 so we also hear devices' own multicast announcements.
        if !bindPort(fd, SLP.shurePort) { _ = bindPort(fd, 0) }
        for i in interfaces {
            var mreq = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(SLP.shureGroup)),
                               imr_interface: in_addr(s_addr: inet_addr(i.ipv4)))
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        }
        var ttl: UInt8 = 8
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1)
        setReceiveTimeout(fd, ms: 250)

        let requests = [
            SLP.serviceRequest(xid: 0x5301, serviceType: "service:service-agent"),
            SLP.serviceRequest(xid: 0x5302, serviceType: "service:service-agent", scope: "default"),
            SLP.serviceTypeRequest(xid: 0x5303),
            SLP.serviceTypeRequest(xid: 0x5304, scope: "default"),
        ]
        let targets = [(SLP.shureGroup, SLP.shurePort), (SLP.standardGroup, SLP.standardPort)]
        func sendAll() {
            for i in interfaces {
                var ifaddr = in_addr(s_addr: inet_addr(i.ipv4))
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, socklen_t(MemoryLayout<in_addr>.size))
                for (group, port) in targets { for r in requests { send(fd, r, to: group, port: port) } }
            }
        }
        sendAll()
        receive(fd, until: Date().addingTimeInterval(duration), resendAt: Date().addingTimeInterval(duration / 2),
                resend: sendAll) { data, ip in
            guard !own.contains(ip), SLP.function(of: data) != nil else { return }
            let fn = SLP.function(of: data) ?? 0
            // Ignore other computers' requests (e.g. WWB asking the same question).
            guard fn != SLP.Function.srvRqst.rawValue, fn != SLP.Function.srvTypeRqst.rawValue else { return }
            let hint = SLP.serviceStrings(in: data).first ?? ""
            DispatchQueue.main.async { found(ip, .shure, hint) }
        }
    }

    // MARK: UHF-R (UDP 2202 broadcast)

    private static func uhfrBroadcast(interfaces: [NetInterface], own: Set<String>, duration: TimeInterval,
                                      found: @escaping (String, DeviceKind, String) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = bindPort(fd, 0)
        setReceiveTimeout(fd, ms: 250)
        let probe = Data(ShureProtocol.uhfr(ShureProtocol.frame("GET 1 CHAN_NAME")).utf8)
        func sendAll() {
            for i in interfaces {
                if let b = IPv4.broadcast(i.ipv4, prefix: i.prefix) { send(fd, probe, to: b, port: ShureProtocol.port) }
            }
        }
        sendAll()
        receive(fd, until: Date().addingTimeInterval(duration), resendAt: Date().addingTimeInterval(duration / 2),
                resend: sendAll) { data, ip in
            guard !own.contains(ip), String(decoding: data, as: UTF8.self).contains("REPORT") else { return }
            DispatchQueue.main.async { found(ip, .shureUHFR, "UHF-R") }
        }
    }

    // MARK: BSD socket helpers

    private static func bindPort(_ fd: Int32, _ port: UInt16) -> Bool {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    private static func setReceiveTimeout(_ fd: Int32, ms: Int) {
        var tv = timeval(tv_sec: ms / 1000, tv_usec: Int32(ms % 1000) * 1000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func send(_ fd: Int32, _ data: Data, to ip: String, port: UInt16) {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr = in_addr(s_addr: inet_addr(ip))
        let bytes = [UInt8](data)
        let count = bytes.count
        _ = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bytes.withUnsafeBytes { Darwin.sendto(fd, $0.baseAddress, count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    private static func receive(_ fd: Int32, until end: Date, resendAt: Date, resend: () -> Void,
                                handle: (Data, String) -> Void) {
        var resent = false
        let size = 4096
        var buf = [UInt8](repeating: 0, count: size)
        while Date() < end {
            if !resent && Date() >= resendAt { resend(); resent = true }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buf.withUnsafeMutableBytes { Darwin.recvfrom(fd, $0.baseAddress, size, 0, sa, &len) }
                }
            }
            guard n > 0 else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            handle(Data(buf[0..<n]), ip)
        }
    }

    // MARK: Check + name

    /// Connects to the control port (TCP 2202) and asks for model and device name.
    static func identify(ip: String, done: @escaping (_ reachable: Bool, _ model: String, _ name: String, _ problem: String) -> Void) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let c = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: ShureProtocol.port)!,
                             using: NetworkManager.shared.parameters(NWParameters(tls: nil, tcp: tcp)))
        final class State { var finished = false; var buffer = ""; var model = ""; var name = "" }
        let s = State()
        func finish(_ ok: Bool, _ problem: String) {
            guard !s.finished else { return }
            s.finished = true
            c.cancel()
            done(ok, s.model, s.name, problem)
        }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, _ in
                if let data { s.buffer += String(decoding: data, as: UTF8.self) }
                for f in ShureProtocol.extractFrames(&s.buffer) {
                    if case .rep(nil, let key, let values)? = ShureProtocol.parse(f) {
                        if key == "MODEL" { s.model = values.first ?? "" }
                        if key == "DEVICE_ID" { s.name = values.first ?? "" }
                    }
                }
                if !s.model.isEmpty && !s.name.isEmpty { finish(true, ""); return }
                if !complete && !s.finished { read() }
            }
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready:
                for cmd in ["GET MODEL", "GET DEVICE_ID"] {
                    c.send(content: Data(ShureProtocol.frame(cmd).utf8), completion: .contentProcessed { _ in })
                }
                read()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(true, "") }
            case .failed(let e), .waiting(let e):
                finish(false, NetworkManager.shared.explain(e, path: c.currentPath))
            default: break
            }
        }
        c.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(false, "No answer on the control port (TCP 2202)") }
    }
}
