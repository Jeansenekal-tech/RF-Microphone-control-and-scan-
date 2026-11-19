import Foundation
import Darwin

struct SerialPortInfo: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var name: String
}

enum SerialError: LocalizedError {
    case open(String), configure(String), timeout(String), io(String)
    var errorDescription: String? {
        switch self {
        case .open(let s): return "Cannot open \(s)"
        case .configure(let s): return "Cannot configure \(s)"
        case .timeout(let s): return "No answer to '\(s)'"
        case .io(let s): return "Serial I/O error: \(s)"
        }
    }
}

/// Minimal blocking POSIX serial port (use from a background queue).
final class SerialPort {
    private var fd: Int32 = -1
    let path: String

    static func available() -> [SerialPortInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.SLAB") }
            .sorted()
            .map { SerialPortInfo(path: "/dev/" + $0, name: $0.replacingOccurrences(of: "cu.", with: "")) }
    }

    init(path: String, baud: Int = 115200) throws {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.open(path) }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { Darwin.close(fd); throw SerialError.configure(path) }
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { Darwin.close(fd); throw SerialError.configure(path) }
        tcflush(fd, TCIOFLUSH)
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    func write(_ s: String) throws {
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EAGAIN { usleep(1000); continue }
                throw SerialError.io(String(cString: strerror(errno)))
            }
            off += n
        }
    }

    /// Reads whatever arrives within `timeout` seconds (returns early once data stops).
    func read(timeout: TimeInterval) throws -> Data {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, Int32(timeout * 1000))
        if r < 0 { throw SerialError.io(String(cString: strerror(errno))) }
        if r == 0 { return Data() }
        if pfd.revents & Int16(POLLHUP | POLLERR) != 0 { throw SerialError.io("device disconnected") }
        let size = 8192
        var buf = [UInt8](repeating: 0, count: size)
        let n = Darwin.read(fd, &buf, size)
        if n < 0 {
            if errno == EAGAIN { return Data() }
            throw SerialError.io(String(cString: strerror(errno)))
        }
        return Data(buf[0..<n])
    }
}
