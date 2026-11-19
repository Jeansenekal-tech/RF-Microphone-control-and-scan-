import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int = 200
    var contentType = "application/json; charset=utf-8"
    var body: Data = Data()

    static func json<T: Encodable>(_ value: T) -> HTTPResponse {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return HTTPResponse(body: (try? e.encode(value)) ?? Data("{}".utf8))
    }
    static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8))
    }
    static func html(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(s.utf8))
    }
}

/// Minimal HTTP/1.1 server on Network.framework (one request per connection).
/// Requests are handled on the main queue so handlers can read app state directly.
final class HTTPServer {
    private var listener: NWListener?
    var handler: ((HTTPRequest) -> HTTPResponse)?
    var onStateChange: ((String) -> Void)?

    func start(port: UInt16) throws {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: p)
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.onStateChange?("Running on port \(port)")
            case .failed(let e): self?.onStateChange?("Stopped: \(e.localizedDescription)")
            case .cancelled: self?.onStateChange?("Stopped")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, buffer: Data())
        // Drop idle connections.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { c.cancel() }
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 1_000_000 || err != nil { c.cancel(); return }
            if let req = Self.parse(buf) {
                let resp = self.handler?(req) ?? .text("Not available", status: 503)
                self.send(resp, on: c)
            } else if done {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    /// Returns a request once the headers and the full body have arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= len else { return nil }
        let target = String(first[1])
        let comps = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(first[0]).uppercased(), path: comps?.percentEncodedPath.removingPercentEncoding ?? target,
                           query: query, headers: headers, body: Data(body.prefix(len)))
    }

    private func send(_ r: HTTPResponse, on c: NWConnection) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 503: "Service Unavailable"][r.status] ?? "OK"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
