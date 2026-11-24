import Foundation

#if os(iOS)
import NetworkExtension

/// 🐱 Ask iPadOS to join the camera's Wi-Fi network (NEHotspotConfiguration).
/// 🐱
/// 🐱 What this can and cannot do:
/// 🐱  - iPadOS always shows its own consent alert; an app can never switch networks silently.
/// 🐱  - Needs the "Hotspot Configuration" capability (paid Apple Developer account). Without it, `apply` fails
/// 🐱    and the user joins manually in Settings > Wi-Fi; the rest of the app works the same.
/// 🐱  - `joinOnce` is left false so the iPad stays on the camera network if the app is briefly backgrounded
/// 🐱    (with joinOnce the system drops the network when the app leaves the foreground).
public enum WiFiJoiner {
    public enum JoinError: Error, CustomStringConvertible {
        case userDenied
        case invalidCredentials(String)
        case systemRefused(String)

        public var description: String {
            switch self {
            case .userDenied: return "Joining was cancelled in the system prompt."
            case let .invalidCredentials(m): return "The network name or password was rejected: \(m)"
            case let .systemRefused(m): return "iPadOS refused the request: \(m). Join the camera network manually in Settings > Wi-Fi."
            }
        }
    }

    public static func join(ssid: String, passphrase: String?) async throws {
        let config: NEHotspotConfiguration
        if let pass = passphrase, !pass.isEmpty {
            config = NEHotspotConfiguration(ssid: ssid, passphrase: pass, isWEP: false)
        } else {
            config = NEHotspotConfiguration(ssid: ssid)
        }
        config.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
            switch NEHotspotConfigurationError(rawValue: error.code) {
            case .alreadyAssociated?:
                return
            case .userDenied?:
                throw JoinError.userDenied
            case .invalidSSID?, .invalidWPAPassphrase?, .invalidWEPPassphrase?, .invalidSSIDPrefix?:
                throw JoinError.invalidCredentials(error.localizedDescription)
            default:
                throw JoinError.systemRefused(error.localizedDescription)
            }
        } catch {
            throw JoinError.systemRefused(error.localizedDescription)
        }
    }

    /// 🐱 Remove the saved camera network so the iPad returns to its usual Wi-Fi.
    public static func forget(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    /// 🐱 SSID of the current Wi-Fi, when iPadOS allows the app to read it (requires the "Access Wi-Fi
    /// 🐱 Information" entitlement and, typically, that this app configured the network). Nil otherwise.
    public static func currentSSID() async -> String? { await currentNetwork()?.ssid }

    /// 🐱 SSID and BSSID (the access point's MAC) of the current Wi-Fi, under the same conditions as above.
    public static func currentNetwork() async -> (ssid: String, bssid: String)? {
        await withCheckedContinuation { c in
            NEHotspotNetwork.fetchCurrent { network in
                c.resume(returning: network.map { ($0.ssid, $0.bssid) })
            }
        }
    }
}
#endif
