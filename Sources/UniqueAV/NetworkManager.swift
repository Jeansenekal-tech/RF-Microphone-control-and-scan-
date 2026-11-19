import Foundation
import Network
import SystemConfiguration
import UniqueAVCore

/// One network connection of this Mac (Ethernet port, Wi-Fi, USB LAN adapter, Thunderbolt bridge…).
struct NetInterface: Identifiable, Equatable {
    var id: String { bsdName }
    var bsdName: String          // "en0"
    var displayName: String      // "Wi-Fi", "USB 10/100/1000 LAN"
    var kind: Kind
    var ipv4: String
    var prefix: Int

    enum Kind { case wifi, ethernet, other }

    var subnet: String { IPv4.subnet(ipv4, prefix: prefix) ?? "\(ipv4)/\(prefix)" }
    /// Self-assigned 169.254.x.x address: no DHCP server on this network (common on a plain show switch).
    var isLinkLocal: Bool { IPv4.isLinkLocal(ipv4) }
    var symbol: String {
        switch kind { case .wifi: return "wifi"; case .ethernet: return "cable.connector"; case .other: return "network" }
    }
    func contains(_ ip: String) -> Bool { IPv4.sameSubnet(ip, ipv4, prefix: prefix) }
}

/// Which network the app uses for receivers and for the phone monitor.
/// Shared, because receiver drivers create their own network connections.
final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    @Published private(set) var interfaces: [NetInterface] = []
    /// Interface used to reach receivers (nil = Automatic: let macOS route by IP address).
    @Published var receiverInterfaceID: String? {
        didSet { save(); if receiverInterfaceID != oldValue { onReceiverNetworkChange?() } }
    }
    /// Interface whose address is used for the phone-monitor QR code (nil = first available).
    @Published var phoneInterfaceID: String? { didSet { save() } }

    /// Set when macOS refuses a connection because Local Network access is turned off for this app.
    @Published var localNetworkDenied = false

    /// Called when the receiver network changes (AppState reconnects all receivers).
    var onReceiverNetworkChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var nwInterfaces: [NWInterface] = []

    private init() {
        let d = UserDefaults.standard
        receiverInterfaceID = d.string(forKey: "network.receivers")
        phoneInterfaceID = d.string(forKey: "network.phone")
        refresh()
        monitor.pathUpdateHandler = { [weak self] path in
            let list = path.availableInterfaces
            DispatchQueue.main.async {
                self?.nwInterfaces = list
                self?.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "uniqueav.network"))
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(receiverInterfaceID, forKey: "network.receivers")
        d.set(phoneInterfaceID, forKey: "network.phone")
    }

    // MARK: Interfaces

    func refresh() {
        let names = Self.displayNames()
        var out: [NetInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { interfaces = []; return }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let ip = Self.numericHost(sa) else { continue }
            let bsd = String(cString: ptr.pointee.ifa_name)
            let mask = ptr.pointee.ifa_netmask.flatMap(Self.numericHost)
            let prefix = mask.flatMap { IPv4.prefixLength(mask: $0) } ?? 24
            let info = names[bsd]
            if out.contains(where: { $0.bsdName == bsd }) { continue }
            out.append(NetInterface(bsdName: bsd, displayName: info?.name ?? bsd, kind: info?.kind ?? .other,
                                    ipv4: ip, prefix: prefix))
        }
        out.sort { ($0.kind == .ethernet ? 0 : $0.kind == .wifi ? 1 : 2, $0.bsdName) <
                   ($1.kind == .ethernet ? 0 : $1.kind == .wifi ? 1 : 2, $1.bsdName) }
        if out != interfaces { interfaces = out }
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(host.count)
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, len, nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    /// BSD name -> ("Wi-Fi", .wifi) from System Configuration.
    private static func displayNames() -> [String: (name: String, kind: NetInterface.Kind)] {
        var out: [String: (name: String, kind: NetInterface.Kind)] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return out }
        for i in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
            let type = SCNetworkInterfaceGetInterfaceType(i) as String? ?? ""
            let kind: NetInterface.Kind = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi
                : type == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet : .other
            out[bsd] = (name, kind)
        }
        return out
    }

    // MARK: Selection

    var receiverInterface: NetInterface? { interfaces.first { $0.id == receiverInterfaceID } }

    var phoneInterface: NetInterface? {
        interfaces.first { $0.id == phoneInterfaceID } ?? interfaces.first { $0.kind == .wifi } ?? interfaces.first
    }

    /// The connection whose subnet contains `ip`, if any.
    func interface(containing ip: String) -> NetInterface? { interfaces.first { $0.contains(ip) } }

    /// Network.framework parameters pinned to the selected receiver interface (if one is chosen).
    func parameters(_ base: NWParameters) -> NWParameters {
        if let id = receiverInterfaceID, let iface = nwInterfaces.first(where: { $0.name == id }) {
            base.requiredInterface = iface
        }
        return base
    }

    /// Addresses to probe when searching for receivers: devices the Mac already knows about (ARP table)
    /// first, then every address on the network. A self-assigned (169.254) network is swept completely.
    func discoveryHosts() -> (known: [String], sweep: [String], linkLocal: Bool) {
        let list = receiverInterface.map { [$0] } ?? interfaces
        let own = Set(interfaces.map(\.ipv4))
        let arp = Self.arpTable()
        var known: [String] = []
        var sweep: [String] = []
        var linkLocal = false
        for i in list {
            known += IPv4.parseARP(arp, interface: i.bsdName).filter { i.contains($0) && !own.contains($0) }
            if i.isLinkLocal {
                linkLocal = true
                sweep += IPv4.linkLocalHosts(excluding: own)
            } else {
                sweep += IPv4.hosts(around: i.ipv4, prefix: i.prefix)
            }
        }
        var seen = Set<String>()
        known = known.filter { seen.insert($0).inserted }
        sweep = sweep.filter { seen.insert($0).inserted }
        return (known, sweep, linkLocal)
    }

    /// Output of `arp -an` (the Mac's table of devices recently seen on the local network).
    static func arpTable() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Explains a failed connection in plain words, and notices when macOS is blocking local network access.
    func explain(_ error: NWError, path: NWPath?) -> String {
        if path?.unsatisfiedReason == .localNetworkDenied {
            localNetworkDenied = true
            return "Blocked by macOS – allow Local Network access (System Settings › Privacy & Security › Local Network)"
        }
        if case .posix(let code) = error {
            switch code {
            case .EHOSTUNREACH, .ENETUNREACH:
                return "No route to receiver – check the Mac is on the receivers' network, and Local Network access is allowed"
            case .ECONNREFUSED:
                return "Receiver refused the connection – is this a Shure receiver with network control (port 2202)?"
            case .ETIMEDOUT:
                return "No answer – check the receiver's IP address and cabling"
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Test

    /// Tries a TCP connection to ip:port over the receiver network. Calls back on the main queue.
    func test(ip: String, port: UInt16, done: @escaping (Bool, String) -> Void) {
        guard IPv4.parse(ip) != nil, let p = NWEndpoint.Port(rawValue: port) else { done(false, "Not a valid IP address"); return }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let c = NWConnection(host: NWEndpoint.Host(ip), port: p, using: parameters(NWParameters(tls: nil, tcp: tcp)))
        final class Once { var fired = false }
        let once = Once()
        let finish: (Bool, String) -> Void = { ok, msg in
            guard !once.fired else { return }
            once.fired = true
            c.cancel()
            done(ok, msg)
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: finish(true, "\(ip) answers on port \(port)")
            case .failed(let e): finish(false, self.explain(e, path: c.currentPath))
            case .waiting(let e): finish(false, self.explain(e, path: c.currentPath))
            default: break
            }
        }
        c.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(false, "No answer from \(ip) on port \(port)") }
    }
}
