import Foundation
import Capacitor

@objc(NetworkBytesPlugin)
public class NetworkBytesPlugin: CAPPlugin {

    // セルラー全体 (テザリング含む) の受信/送信バイト数を返す。
    // pdp_ip0 はキャリア経由トラフィックの集約インタフェース。
    // Wi-Fi上のテザリング通信量だけを切り出すAPIはiOSに存在しない。
    @objc func readCounters(_ call: CAPPluginCall) {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var found = false

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            call.resolve([
                "rxBytes": 0,
                "txBytes": 0,
                "interfaceFound": false
            ])
            return
        }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let name = String(cString: p.pointee.ifa_name)
            if name == "pdp_ip0", let raw = p.pointee.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                rx &+= UInt64(data.ifi_ibytes)
                tx &+= UInt64(data.ifi_obytes)
                found = true
            }
            cursor = p.pointee.ifa_next
        }

        call.resolve([
            "rxBytes": rx,
            "txBytes": tx,
            "interfaceFound": found
        ])
    }
}
