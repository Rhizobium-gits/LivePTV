import Foundation

/// 🐱 Camera network details bundled with the app (App/Camera.local.plist, excluded from git), so the app can
/// 🐱 join and connect by itself on launch. Keys: SSID, Password, MACAddress (optional), Host, Port (optional).
public struct CameraPreset: Equatable, Sendable {
    public var ssid: String
    public var password: String
    public var macAddress: String?
    public var host: String?
    public var port: UInt16?

    public static let resourceName = "Camera.local"

    public static func load(from bundle: Bundle = .main) -> CameraPreset? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let ssid = dict["SSID"] as? String, !ssid.isEmpty else { return nil }
        return CameraPreset(ssid: ssid,
                            password: dict["Password"] as? String ?? "",
                            macAddress: (dict["MACAddress"] as? String).flatMap(normalizeMAC),
                            host: dict["Host"] as? String,
                            port: (dict["Port"] as? Int).flatMap { UInt16(exactly: $0) })
    }

    /// 🐱 "02:11:2A:33:44:55", "02-11-2a-33-44-55" and iOS-style "02:11:2a:33:44:55" (leading zeros sometimes dropped)
    /// 🐱 all become "02:11:2a:33:44:55". Nil if it is not a 6-octet MAC.
    public static func normalizeMAC(_ s: String) -> String? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var octets: [String] = []
        for p in parts {
            guard p.count <= 2, let v = UInt8(p, radix: 16) else { return nil }
            octets.append(String(format: "%02x", v))
        }
        return octets.joined(separator: ":")
    }
}
