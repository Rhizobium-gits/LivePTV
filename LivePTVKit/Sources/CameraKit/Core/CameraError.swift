import Foundation

/// 🐱 Every failure a video source can report, each with a short diagnosis the UI can show verbatim.
public enum CameraError: Error, Equatable, Sendable, CustomStringConvertible {
    case notOnWiFi
    case wrongNetwork(localAddress: String?, expectedSubnet: String)
    case localNetworkDenied
    case cameraUnreachable(host: String, port: UInt16, reason: String)
    case connectionRefused(host: String, port: UInt16)
    case handshakeTimeout
    case protocolViolation(String)
    case commandTimeout(command: String)
    case commandRejected(command: String, code: Int, message: String?)
    case previewRejected(triedResolutions: [String])
    case streamStalled(seconds: Double)
    case connectionLost(String)
    case decoderFailure(status: Int32, detail: String)
    case fileError(String)
    case deviceUnavailable(String)
    case notConnected
    case unsupported(String)

    public var description: String {
        switch self {
        case .notOnWiFi:
            return "The iPad is not connected to any Wi-Fi network."
        case let .wrongNetwork(addr, subnet):
            return "The iPad's Wi-Fi address (\(addr ?? "none")) is not in the camera subnet \(subnet)."
        case .localNetworkDenied:
            return "Local Network access is denied for this app."
        case let .cameraUnreachable(host, port, reason):
            return "Camera at \(host):\(port) is unreachable (\(reason))."
        case let .connectionRefused(host, port):
            return "Camera at \(host):\(port) refused the connection."
        case .handshakeTimeout:
            return "Camera did not answer the protocol handshake."
        case let .protocolViolation(detail):
            return "Unexpected data from camera: \(detail)."
        case let .commandTimeout(cmd):
            return "Camera did not answer \(cmd)."
        case let .commandRejected(cmd, code, msg):
            return "Camera rejected \(cmd) (code \(code)\(msg.map { ": \($0)" } ?? ""))."
        case let .previewRejected(tried):
            return "Camera rejected every preview configuration (\(tried.joined(separator: ", ")))."
        case let .streamStalled(s):
            return String(format: "No video received for %.1f s.", s)
        case let .connectionLost(why):
            return "Connection lost: \(why)."
        case let .decoderFailure(status, detail):
            return "Video decoder error \(status): \(detail)."
        case let .fileError(detail):
            return "File error: \(detail)."
        case let .deviceUnavailable(detail):
            return "Device unavailable: \(detail)."
        case .notConnected:
            return "Not connected."
        case let .unsupported(detail):
            return "Not supported: \(detail)."
        }
    }

    /// 🐱 What the operator should try next. Written for someone standing next to the experiment.
    public var hint: String {
        switch self {
        case .notOnWiFi:
            return "Open Settings > Wi-Fi on the iPad and join the camera's network (its name starts with the camera model), then come back to this app."
        case .wrongNetwork:
            return "The iPad is on a different Wi-Fi network. Join the camera's network in Settings > Wi-Fi. If iPadOS switched back automatically because the camera network has no internet, turn off Auto-Join for your usual network while experimenting."
        case .localNetworkDenied:
            return "Open Settings > Privacy & Security > Local Network and enable this app, then try again."
        case .cameraUnreachable:
            return "Check that the camera is on, its Wi-Fi is enabled (swipe down on the camera screen), and that it is not in USB mode. Move the iPad closer to the camera."
        case .connectionRefused:
            return "The camera's Wi-Fi is up but its control service is not accepting connections. Close the Insta360 app on any phone connected to this camera, or restart the camera's Wi-Fi."
        case .handshakeTimeout, .protocolViolation:
            return "The camera answered with an unexpected protocol. Its firmware may differ from what this app supports. Run the protocol probe and keep the capture file for analysis."
        case .commandTimeout:
            return "The camera is busy or the link is poor. Wait a moment and retry."
        case .commandRejected, .previewRejected:
            return "Put the camera in plain Video mode (not timelapse, photo or webcam mode) and retry. Stop any recording that is already running."
        case .streamStalled:
            return "Wi-Fi signal may be weak or the camera may have stopped the preview. The app will request a key frame and then reconnect automatically."
        case .connectionLost:
            return "The app will try to reconnect. If it keeps failing, check the camera battery and Wi-Fi range."
        case .decoderFailure:
            return "The decoder will restart at the next key frame. If this repeats, lower the preview resolution."
        case .fileError:
            return "Check that the file exists and is a video the iPad can play."
        case .deviceUnavailable:
            return "Reconnect the USB cable and check that the camera is in webcam mode."
        case .notConnected:
            return "Connect first."
        case .unsupported:
            return "This feature is not available for the current source."
        }
    }
}
