import Foundation
import Capacitor
import Network
import Darwin

// 同じLAN(主にiPhoneのテザリング先デバイス)からTetherDashの現在値を
// 閲覧できるよう、簡易HTTPサーバを立てるプラグイン。
// - NWListener ベースで Cocoapods 依存なし
// - JS側から start()/stop()/updateState() で操作
// - GET /         : Windows向けビューワHTML
// - GET /dashboard: 同上 (エイリアス)
// - GET /state.json: 直近の updateState で受け取った状態をそのまま返す
@objc(LocalServerPlugin)
public class LocalServerPlugin: CAPPlugin {

    private var listener: NWListener?
    private var port: UInt16 = 8080
    private let stateLock = NSLock()
    private var currentState: [String: Any] = [:]
    private let serverQueue = DispatchQueue(label: "tetherdash.localserver", qos: .userInitiated)

    @objc func start(_ call: CAPPluginCall) {
        let p = call.getInt("port") ?? 8080
        self.port = UInt16(p)
        do {
            try startServer()
            call.resolve(buildStatusDict(running: true))
        } catch {
            call.reject("server start failed: \(error.localizedDescription)")
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        listener?.cancel()
        listener = nil
        call.resolve(["running": false])
    }

    @objc func updateState(_ call: CAPPluginCall) {
        if let state = call.getObject("state") {
            stateLock.lock()
            currentState = state
            stateLock.unlock()
        }
        call.resolve()
    }

    @objc func getStatus(_ call: CAPPluginCall) {
        call.resolve(buildStatusDict(running: listener != nil))
    }

    private func buildStatusDict(running: Bool) -> [String: Any] {
        let ips = Self.getLocalIPv4Addresses()
        let preferred = Self.pickPreferredIP(ips)
        return [
            "running": running,
            "port": Int(self.port),
            "preferredUrl": preferred.map { "http://\($0):\(self.port)/" } ?? "",
            "addresses": ips.map { ["interface": $0.interface, "ip": $0.ip] }
        ]
    }

    private func startServer() throws {
        listener?.cancel()
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
            throw NSError(domain: "LocalServer", code: -1)
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        l.start(queue: serverQueue)
        self.listener = l
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: serverQueue)
        receiveRequest(conn)
    }

    private func receiveRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let req = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let path = self.parsePath(req)
            let (status, headers, body) = self.handleRequest(path: path)
            self.sendResponse(conn, status: status, headers: headers, body: body)
        }
    }

    private func parsePath(_ req: String) -> String {
        let firstLine = req.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return "/" }
        return parts[1].components(separatedBy: "?").first ?? "/"
    }

    private func handleRequest(path: String) -> (Int, [String: String], Data) {
        switch path {
        case "/", "/dashboard":
            let html = Self.loadViewerHTML()
            return (200, ["Content-Type": "text/html; charset=utf-8"], html.data(using: .utf8) ?? Data())
        case "/state.json":
            stateLock.lock()
            let state = currentState
            stateLock.unlock()
            if let data = try? JSONSerialization.data(withJSONObject: state, options: []) {
                return (200, ["Content-Type": "application/json", "Access-Control-Allow-Origin": "*"], data)
            }
            return (500, [:], "serialize error".data(using: .utf8) ?? Data())
        default:
            return (404, ["Content-Type": "text/plain"], "Not Found".data(using: .utf8) ?? Data())
        }
    }

    private func sendResponse(_ conn: NWConnection, status: Int, headers: [String: String], body: Data) {
        var header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        for (k, v) in headers {
            header += "\(k): \(v)\r\n"
        }
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var responseData = header.data(using: .utf8) ?? Data()
        responseData.append(body)
        conn.send(content: responseData, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func loadViewerHTML() -> String {
        if let url = Bundle.main.url(forResource: "public/remote", withExtension: "html"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        return "<!DOCTYPE html><html><body><h1>Remote viewer not bundled</h1></body></html>"
    }

    // 優先順: bridge100 (iOSテザリング) > en0 (Wi-Fi) > その他
    private static func pickPreferredIP(_ ips: [(interface: String, ip: String)]) -> String? {
        if let h = ips.first(where: { $0.interface == "bridge100" }) { return h.ip }
        if let w = ips.first(where: { $0.interface == "en0" }) { return w.ip }
        return ips.first?.ip
    }

    static func getLocalIPv4Addresses() -> [(interface: String, ip: String)] {
        var addresses: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let curr = ptr {
            if let addrPtr = curr.pointee.ifa_addr {
                let family = addrPtr.pointee.sa_family
                if family == UInt8(AF_INET) {
                    let name = String(cString: curr.pointee.ifa_name)
                    let exclude = name == "lo0" || name.hasPrefix("utun") || name.hasPrefix("pdp") || name.hasPrefix("ipsec") || name.hasPrefix("awdl")
                    if !exclude {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let r = getnameinfo(addrPtr, socklen_t(addrPtr.pointee.sa_len),
                                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                        if r == 0 {
                            addresses.append((name, String(cString: host)))
                        }
                    }
                }
            }
            ptr = curr.pointee.ifa_next
        }
        return addresses
    }
}
