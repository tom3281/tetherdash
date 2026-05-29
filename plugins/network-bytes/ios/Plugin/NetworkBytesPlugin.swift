import Foundation
import Capacitor
import Darwin
import CoreTelephony

@objc(NetworkBytesPlugin)
public class NetworkBytesPlugin: CAPPlugin {

    // Darwin module 経由でSwiftからは見えない C マクロを明示定義
    // (net/route.h) RTM_IFINFO2 = 0x12, NET_RT_IFLIST2 = 6
    private static let RTM_IFINFO2_VAL: Int32 = 0x12
    private static let NET_RT_IFLIST2_VAL: Int32 = 6

    private let telephonyInfo = CTTelephonyNetworkInfo()

    // セルラー(pdp_ip0)の受信/送信バイト数を 64bit で返す。
    // getifaddrs() の if_data は 32bit (4GB ロールオーバー) なので、
    // sysctl(NET_RT_IFLIST2) + if_msghdr2.ifm_data (if_data64) を使う。
    @objc func readCounters(_ call: CAPPluginCall) {
        let (rx, tx, found) = NetworkBytesPlugin.readInterfaceBytes(name: "pdp_ip0")
        call.resolve([
            "rxBytes": NSNumber(value: rx),
            "txBytes": NSNumber(value: tx),
            "interfaceFound": found
        ])
    }

    // 現在のセルラー無線技術を返す。
    // CoreTelephony の serviceCurrentRadioAccessTechnology は公式API、審査も通る。
    // dual-SIM 等で複数値がある場合、最も上位の世代を優先する。
    @objc func getRadioTech(_ call: CAPPluginCall) {
        var rawValues: [String] = []
        if let dict = telephonyInfo.serviceCurrentRadioAccessTechnology {
            rawValues = Array(dict.values)
        }
        let best = NetworkBytesPlugin.pickBestRadio(rawValues)
        let label = NetworkBytesPlugin.mapTechToLabel(best)
        call.resolve([
            "tech": best ?? "",
            "label": label,
            "available": (best != nil)
        ])
    }

    private static func pickBestRadio(_ values: [String]) -> String? {
        // 優先順位: 5G > 4G > 3G > 2G
        let ranking: [String] = {
            var arr: [String] = []
            if #available(iOS 14.1, *) {
                arr += [CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA]
            }
            arr += [
                CTRadioAccessTechnologyLTE,
                CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA, CTRadioAccessTechnologyWCDMA,
                CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyCDMAEVDORevA,
                CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyeHRPD,
                CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyCDMA1x
            ]
            return arr
        }()
        for r in ranking {
            if values.contains(r) { return r }
        }
        return values.first
    }

    private static func mapTechToLabel(_ tech: String?) -> String {
        guard let t = tech else { return "" }
        if #available(iOS 14.1, *) {
            if t == CTRadioAccessTechnologyNR || t == CTRadioAccessTechnologyNRNSA {
                return "5G"
            }
        }
        switch t {
        case CTRadioAccessTechnologyLTE:
            return "4G"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            return "3G"
        case CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyCDMA1x:
            return "2G"
        default:
            return ""
        }
    }

    private static func readInterfaceBytes(name targetName: String) -> (rx: UInt64, tx: UInt64, found: Bool) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2_VAL, 0]
        var len: size_t = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else {
            return (0, 0, false)
        }

        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: len)
        defer { buf.deallocate() }

        guard sysctl(&mib, UInt32(mib.count), buf, &len, nil, 0) == 0 else {
            return (0, 0, false)
        }

        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0
        var found = false

        var offset = 0
        while offset < len {
            let ifmRaw = UnsafeRawPointer(buf).advanced(by: offset)
            let ifm = ifmRaw.assumingMemoryBound(to: if_msghdr.self).pointee
            let msgLen = Int(ifm.ifm_msglen)
            guard msgLen > 0 else { break }

            if Int32(ifm.ifm_type) == RTM_IFINFO2_VAL {
                let ifm2 = ifmRaw.assumingMemoryBound(to: if_msghdr2.self).pointee
                let sdlRaw = ifmRaw.advanced(by: MemoryLayout<if_msghdr2>.size)
                let sdl = sdlRaw.assumingMemoryBound(to: sockaddr_dl.self).pointee

                let nameLen = Int(sdl.sdl_nlen)
                if nameLen > 0 {
                    var chars = [CChar]()
                    withUnsafePointer(to: sdl.sdl_data) { dataPtr in
                        let cPtr = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: CChar.self)
                        for j in 0..<nameLen {
                            chars.append(cPtr.advanced(by: j).pointee)
                        }
                    }
                    chars.append(0)
                    let detectedName = String(cString: chars)

                    if detectedName == targetName {
                        rxTotal &+= ifm2.ifm_data.ifi_ibytes
                        txTotal &+= ifm2.ifm_data.ifi_obytes
                        found = true
                    }
                }
            }

            offset += msgLen
        }

        return (rxTotal, txTotal, found)
    }
}
