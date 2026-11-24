import CameraKit
import CoreGraphics
import CoreVideo
import Foundation
import Pipeline
import PTVCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

public enum SourceChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case aceProWiFi = "Ace Pro 2 (Wi-Fi)"
    case synthetic = "Test pattern"
    case videoFile = "Video file"
    case usbCamera = "USB camera"
    public var id: String { rawValue }
}

public enum USBResolution: String, CaseIterable, Identifiable, Sendable {
    case p360 = "640×360", p720 = "1280×720", p1080 = "1920×1080"
    public var id: String { rawValue }
    var size: (Int, Int) {
        switch self {
        case .p360: return (640, 360)
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        }
    }
}

public enum EditTarget: Sendable {
    case analysisRegion, shakeReference
    /// 🐱 the container outline (round bottle: drag across its outer silhouette, from below the free surface to above the bottom)
    case container
    /// 🐱 an area to ignore (label, ruler, a reflection the automatic masks miss)
    case exclusion

    var hint: String {
        switch self {
        case .analysisRegion: return "Drag to draw the analysis region"
        case .shakeReference: return "Drag over something that does not move (wall, ruler)"
        case .container: return "Drag from one outer edge of the bottle to the other (top: below the free surface, bottom: above the base)"
        case .exclusion: return "Drag over an area to ignore (label, ruler, a reflection)"
        }
    }
}

public enum SyntheticChoice: String, CaseIterable, Identifiable, Sendable {
    case vortex = "Vortex", rotation = "Rotation", channel = "Channel flow", uniform = "Uniform"
    case slowShaky = "Slow vortex + camera shake"
    public var id: String { rawValue }

    var flow: SyntheticFlow {
        switch self {
        case .vortex: return .lambOseen(circulation: 60_000, coreRadius: 60)
        case .rotation: return .solidBodyRotation(omega: 0.4)
        case .channel: return .poiseuille(uMax: 120)
        case .uniform: return .uniform(u: 60, v: 20)
        case .slowShaky: return .lambOseen(circulation: 4_000, coreRadius: 60)   // 🐱 ≤ 0.2 px per frame
        }
    }
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let time: Date
    public let level: LogLevel
    public let message: String
}

public struct DisplayOptions: Codable, Equatable, Sendable {
    public var particles = true
    public var tails = true
    public var vectors = true
    /// 🐱 Arrow length = speed × this many seconds (in image pixels).
    public var vectorSeconds = 0.4
    /// 🐱 Scale arrows to the current speeds so small motions stay visible (overrides `vectorSeconds`).
    public var autoArrowScale = true
    /// 🐱 Colour map under the vectors (live sliding-window field).
    public var heatmap: HeatmapQuantity = .speed
    public var heatmapOpacity = 0.55
    /// 🐱 Tint what the analysis ignores (outside the fluid, wall band, glare, glints, exclusions).
    public var showMask = true
}

/// 🐱 Owns the active source, the analysis pipeline and the recording; publishes state for the views.
@MainActor
public final class AppModel: ObservableObject {
    // 🐱 MARK: user choices
    @Published public var sourceChoice: SourceChoice = .aceProWiFi
    @Published public var host = Insta360Protocol.defaultHost
    @Published public var port = String(Insta360Protocol.defaultPort)
    @Published public var ssid = UserDefaults.standard.string(forKey: "camera.ssid") ?? "" {
        didSet { UserDefaults.standard.set(ssid, forKey: "camera.ssid") }
    }
    /// 🐱 Kept in memory only (prefilled from App/Camera.local.plist when bundled); the camera shows it under
    /// 🐱 Settings > Wi-Fi Settings.
    @Published public var wifiPassword = ""
    /// 🐱 Camera MAC from its settings; compared with the BSSID of the joined network to confirm the right camera.
    @Published public var cameraMAC = ""
    /// 🐱 On launch / return to the app: join the camera Wi-Fi, connect and start the preview.
    @Published public var autoConnectOnLaunch = UserDefaults.standard.object(forKey: "camera.autoConnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnectOnLaunch, forKey: "camera.autoConnect") }
    }
    @Published public var preferredResolution: Insta360Messages.PreviewResolution = .res1920x1080p30
    @Published public var lowLatencyAssembly = false
    @Published public var videoFileURL: URL?
    @Published public var filePacing: VideoFileSource.Pacing = .realTime
    @Published public var syntheticChoice: SyntheticChoice = .vortex
    @Published public var usbDeviceID: String?
    /// 🐱 720p keeps the analysis fast; the display always shows every camera frame.
    @Published public var usbResolution: USBResolution = .p720
    @Published public var display = DisplayOptions() {
        didSet { updateOverlayConfig() }
    }
    @Published public private(set) var lastEvaluation: SessionEvaluation?
    @Published public var showEvaluation = false
    @Published public var editingROI = false
    @Published public var editTarget: EditTarget = .analysisRegion
    @Published public var settings: AnalysisSettings {
        didSet {
            pipeline?.settings = settings
            updateOverlayConfig()
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "analysis.settings") }
        }
    }

    // 🐱 MARK: state
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var previewRunning = false
    @Published public private(set) var wifiSummary = "checking…"
    @Published public private(set) var inCameraSubnet = false
    @Published public private(set) var cameraReachable: Bool?
    @Published public private(set) var streamParameters: StreamParameters?
    @Published public private(set) var cameraInfoText: String?
    @Published public private(set) var lastError: CameraError?
    @Published public private(set) var diagnostics: [NetworkDiagnostics.Step] = []
    @Published public private(set) var diagnosing = false
    @Published public private(set) var logs: [LogEntry] = []
    /// 🐱 High-rate state lives in separate objects so frames and results never re-render the settings panel.
    public let live: LiveOverlayModel
    public let metricsModel: MetricsModel
    /// 🐱 Camera frames go from the source thread straight to this layer (see VideoDisplay).
    public let videoDisplay: VideoDisplay
    /// 🐱 Folder chosen in the Files app for all sessions (nil = app's own storage).
    @Published public private(set) var exportFolderName: String?
    @Published public private(set) var lastDiagnosticsURL: URL?
    /// 🐱 Latest pipeline numbers (not published; the metrics bar observes `metricsModel`).
    public var metrics: PipelineMetrics { pipeline?.metrics ?? metricsModel.metrics }
    @Published public private(set) var usbDevices: [(id: String, name: String)] = []
    @Published public var busy = false
    @Published public var notice: String?
    @Published public private(set) var autoConnectStatus: String?
    @Published public private(set) var bssidCheck: (ok: Bool?, text: String)?
    @Published public private(set) var presetLoaded = false

    // 🐱 MARK: recording / latency
    @Published public var sessionLabel = ""
    @Published public var recordOnCamera = false
    @Published public var archivePreview = true
    @Published public private(set) var recordingSince: Date?
    @Published public private(set) var lastSessionURL: URL?
    @Published public private(set) var latencyTestRunning = false
    @Published public private(set) var flashBright = false
    @Published public private(set) var latencyResultText: String?

    private var source: CameraVideoSource?
    private var pipeline: AnalysisPipeline?
    private var cameraRecording: SessionMetadata.CameraRecording?
    private var monitorTask: Task<Void, Never>?
    private let overlayBuilder = OverlayBuilder()
    private let overlayPoster: LatestOnMain<OverlayData>
    private let metricsPoster: LatestOnMain<(PipelineMetrics, String)>
    nonisolated(unsafe) private var lastMetricsPost = 0.0
    private var autoConnecting = false
    private var exportFolderURL: URL?
    /// 🐱 Set when the user stops/disconnects by hand: no automatic reconnection until the next launch.
    private var userStopped = false

    /// 🐱 `preset`: camera Wi-Fi details (default: App/Camera.local.plist in the app bundle).
    public init(preset: CameraPreset? = CameraPreset.load()) {
        let live = LiveOverlayModel(), metricsModel = MetricsModel()
        self.live = live
        self.metricsModel = metricsModel
        overlayPoster = LatestOnMain { o in live.set(o) }
        metricsPoster = LatestOnMain { m in metricsModel.set(m.0, status: m.1) }
        videoDisplay = VideoDisplay()
        // 🐱 the GPU correlator compiles its shader and checks itself on first use (≈0.3 s): do it off the main thread
        Task.detached(priority: .utility) { _ = PIVEngine.gpuName }
        if let data = UserDefaults.standard.data(forKey: "analysis.settings"),
           let saved = AnalysisSettings.decodeMerged(data) {
            settings = saved
        } else {
            settings = AnalysisSettings()
        }
        if let preset {
            sourceChoice = .aceProWiFi
            ssid = preset.ssid
            wifiPassword = preset.password
            cameraMAC = preset.macAddress ?? ""
            if let h = preset.host { host = h }
            if let p = preset.port { port = String(p) }
            presetLoaded = true
        }
        videoDisplay.onSizeChange = { size in
            DispatchQueue.main.async { MainActor.assumeIsolated { live.setVideoSize(size) } }
        }
        updateOverlayConfig()
        restoreExportFolder()
        startNetworkMonitor()
    }

    public var isActive: Bool { connectionState.isActive || previewRunning }

    public var sessionsDirectory: URL {
        if let u = exportFolderURL { return u }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // 🐱 MARK: passive network monitor (never touches the camera on its own)

    private func startNetworkMonitor() {
        monitorTask = Task { [weak self] in
            var wasInSubnet = false
            while !Task.isCancelled {
                guard let self else { return }
                let (names, wifi, match) = await self.cameraSubnetMatch()
                let host = self.host
                // 🐱 assign only on change: every assignment re-renders the views observing the model
                if self.inCameraSubnet != (match != nil) { self.inCameraSubnet = match != nil }
                let summary: String
                if names.isEmpty {
                    summary = "No Wi-Fi connection"
                } else if let m = match {
                    summary = "On camera network (\(m.ipv4))"
                } else {
                    summary = "Wi-Fi \(wifi.map(\.ipv4).joined(separator: ", ")) — not the camera network"
                }
                if self.wifiSummary != summary { self.wifiSummary = summary }
                // 🐱 One TCP check when the iPad newly lands on the camera subnet; none otherwise.
                if match != nil && !wasInSubnet && self.sourceChoice == .aceProWiFi && !self.isActive && !self.autoConnecting {
                    let outcome = await NetworkDiagnostics.probeTCP(host: host, port: UInt16(self.port) ?? 6666, timeout: 2, requireWiFi: Self.requireWiFi)
                    if case .reachable = outcome { self.cameraReachable = true } else { self.cameraReachable = false }
                }
                if match == nil, names.isEmpty, self.cameraReachable != false { self.cameraReachable = false }
                wasInSubnet = match != nil
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// 🐱 Wi-Fi interface names, their addresses, and the one in the camera's subnet (if any).
    private func cameraSubnetMatch() async -> ([String], [InterfaceAddress], InterfaceAddress?) {
        let names = await NetworkDiagnostics.currentWiFiInterfaceNames()
        let all = NetworkDiagnostics.ipv4Interfaces()
        let wifi = all.filter { names.contains($0.name) }
        let candidates = wifi.isEmpty ? all : wifi
        let host = self.host
        return (names, wifi, candidates.first { $0.contains(host: host) })
    }

    // 🐱 MARK: automatic join + connect

    /// 🐱 Join the camera Wi-Fi (iPadOS asks for confirmation the first time), wait for an address on the camera
    /// 🐱 subnet, check the BSSID against the camera MAC, connect and start the preview. Safe to call repeatedly.
    public func autoConnect(reason: String) async {
        guard autoConnectOnLaunch, !userStopped, sourceChoice == .aceProWiFi, !isActive, !autoConnecting, !busy, !ssid.isEmpty else { return }
        autoConnecting = true
        defer { autoConnecting = false }
        appendLog(.info, "Auto-connect (\(reason)) to \(ssid)")

        if await cameraSubnetMatch().2 == nil {
            #if os(iOS)
            autoConnectStatus = "Joining \(ssid)…"
            do {
                try await WiFiJoiner.join(ssid: ssid, passphrase: wifiPassword)
            } catch {
                autoConnectStatus = "Could not join automatically (\(error)). Join \(ssid) in Settings > Wi-Fi; the app connects when you come back."
                appendLog(.warning, autoConnectStatus!)
                return
            }
            autoConnectStatus = "Waiting for an address on the camera network…"
            var joined = false
            for _ in 0..<40 {
                if await cameraSubnetMatch().2 != nil { joined = true; break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard joined else {
                autoConnectStatus = "Joined \(ssid) but got no address on the camera network within 20 s. Check that the camera's Wi-Fi is on."
                appendLog(.warning, autoConnectStatus!)
                return
            }
            #else
            autoConnectStatus = "Join \(ssid) on this Mac first; then press Connect."
            return
            #endif
        }

        await checkBSSID()
        autoConnectStatus = "Connecting to the camera…"
        await connect()
        guard connectionState.isActive else {
            autoConnectStatus = "Automatic connection failed; see the error below."
            return
        }
        await startPreview()
        autoConnectStatus = previewRunning ? "Connected automatically" : "Connected, but the preview did not start; see the error below."
    }

    /// 🐱 Compare the joined access point's BSSID with the camera MAC. The AP address can legitimately differ from the
    /// 🐱 MAC shown in the camera menu (e.g. one bit or the last digit), so a mismatch is a warning, not a failure.
    private func checkBSSID() async {
        guard let expected = CameraPreset.normalizeMAC(cameraMAC) else { bssidCheck = nil; return }
        #if os(iOS)
        guard let net = await WiFiJoiner.currentNetwork(), let bssid = CameraPreset.normalizeMAC(net.bssid) else {
            bssidCheck = (nil, "BSSID not readable (needs the Access Wi-Fi Information capability)")
            return
        }
        if bssid == expected {
            bssidCheck = (true, "BSSID \(bssid) matches the camera MAC")
        } else {
            bssidCheck = (false, "BSSID \(bssid) differs from camera MAC \(expected)\(net.ssid == ssid ? " (SSID matches; the AP address may differ from the device MAC)" : " and SSID is \(net.ssid)")")
            appendLog(.warning, bssidCheck!.text)
        }
        #else
        bssidCheck = (nil, "BSSID check is only available on iPad")
        #endif
    }

    public func resumeAutoConnect() {
        userStopped = false
        Task { await autoConnect(reason: "manual") }
    }

    static var requireWiFi: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    // 🐱 MARK: source life cycle

    private func makeSource() throws -> CameraVideoSource {
        switch sourceChoice {
        case .aceProWiFi:
            var c = Insta360AcePro2WiFiSource.Configuration()
            c.host = host
            c.port = UInt16(port) ?? Insta360Protocol.defaultPort
            c.requireWiFiInterface = Self.requireWiFi
            let all: [Insta360Messages.PreviewResolution] = [.res1920x1080p30, .res1280x720p30, .res1440x720p30]
            c.previewResolutions = [preferredResolution] + all.filter { $0 != preferredResolution }
            c.assemblyMode = lowLatencyAssembly ? .lowLatency : .safe
            c.emitCompressedAccessUnits = true
            return Insta360AcePro2WiFiSource(configuration: c)
        case .synthetic:
            var c = TestVideoSource.Configuration()
            c.flow = syntheticChoice.flow
            if settings.method == .piv {
                // 🐱 PIV needs dense seeding (~10–20 particle images per 32×32 window)
                c.particleCount = 6000
                c.particleSigma = 1.0
            }
            if syntheticChoice == .slowShaky {
                c.staticMarginFraction = 0.15
                c.shakeStdPx = 0.6
                c.shakeRotationStd = 0.0005
            }
            return TestVideoSource(configuration: c)
        case .videoFile:
            guard let url = videoFileURL else { throw CameraError.fileError("choose a video file first") }
            return VideoFileSource(url: url, pacing: filePacing)
        case .usbCamera:
            let size = usbResolution.size
            return ExternalCameraSource(deviceUniqueID: usbDeviceID, preferredWidth: size.0, preferredHeight: size.1)
        }
    }

    private func attach(_ s: CameraVideoSource) {
        s.onEvent = { [weak self] event in
            // 🐱 Recording side effects first, off the main thread (compressed pictures arrive 30×/s).
            if let p = self?.pipelineForEvents { p.handleSourceEvent(event) }
            if case .compressedAccessUnit = event { return }
            Task { @MainActor [weak self] in self?.handle(event) }
        }
    }

    /// 🐱 Read from the source's event queue; only replaced on the main actor while the source is idle.
    nonisolated(unsafe) private var pipelineForEvents: AnalysisPipeline?

    private func handle(_ e: SourceEvent) {
        switch e {
        case let .stateChanged(s):
            connectionState = s
            if case let .failed(err) = s { lastError = err }
            if s.isActive { lastError = nil; cameraReachable = sourceChoice == .aceProWiFi ? true : cameraReachable }
        case let .streamParameters(p):
            streamParameters = p
        case let .log(level, message):
            appendLog(level, message)
        case .compressedAccessUnit:
            break
        }
    }

    private func appendLog(_ level: LogLevel, _ message: String) {
        logs.append(LogEntry(time: Date(), level: level, message: message))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    public func sourceChoiceChanged() {
        guard !isActive else { return }
        source = nil
        streamParameters = nil
        cameraInfoText = nil
        lastError = nil
        clearPreview()
        if sourceChoice == .usbCamera { refreshUSBDevices() }
    }

    public func connect() async {
        userStopped = false
        busy = true
        defer { busy = false }
        do {
            if source == nil {
                let s = try makeSource()
                attach(s)
                source = s
            }
            try await source!.connect()
            if let ace = source as? Insta360AcePro2WiFiSource, let info = ace.cameraInfo {
                cameraInfoText = [info.cameraType, info.firmware.map { "firmware \($0)" }].compactMap { $0 }.joined(separator: ", ")
            }
            cameraReachable = sourceChoice == .aceProWiFi ? true : nil
        } catch let e as CameraError {
            lastError = e
            if sourceChoice == .aceProWiFi { cameraReachable = false }
        } catch {
            lastError = .unsupported(error.localizedDescription)
        }
    }

    public func startPreview() async {
        userStopped = false
        busy = true
        defer { busy = false }
        do {
            if source == nil {
                let s = try makeSource()
                attach(s)
                source = s
            }
            guard let s = source else { return }
            let p = AnalysisPipeline(source: s, settings: settings)
            p.onResult = { [weak self] r in self?.receive(r) }
            p.onPreviewFrame = { [weak self] f in self?.receivePreview(f) }
            overlayBuilder.reset()
            pipeline = p
            pipelineForEvents = p
            try await s.startPreview()
            p.start()
            previewRunning = true
            setScreenAlwaysOn(true)
            if let ace = s as? Insta360AcePro2WiFiSource, let info = ace.cameraInfo {
                cameraInfoText = [info.cameraType, info.firmware.map { "firmware \($0)" }].compactMap { $0 }.joined(separator: ", ")
            }
        } catch let e as CameraError {
            lastError = e
            pipeline = nil
            pipelineForEvents = nil
        } catch {
            lastError = .unsupported(error.localizedDescription)
        }
    }

    public func stopPreview() async {
        userStopped = true
        if recordingSince != nil { await stopRecording() }
        if latencyTestRunning { pipeline?.latencyProbe.end() }
        await source?.stopPreview()
        await pipeline?.stop()
        previewRunning = false
        setScreenAlwaysOn(false)
    }

    /// 🐱 Keep the iPad awake during a measurement (auto-lock would background the app and cut the stream).
    private func setScreenAlwaysOn(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    public func disconnect() async {
        await stopPreview()
        await source?.disconnect()
        source = nil
        pipeline = nil
        pipelineForEvents = nil
        connectionState = .disconnected
    }

    public func runDiagnostics() async {
        diagnosing = true
        defer { diagnosing = false }
        diagnostics = await NetworkDiagnostics.checkPath(to: host, port: UInt16(port) ?? 6666, requireWiFi: Self.requireWiFi)
        cameraReachable = diagnostics.last?.status == .pass
    }

    public func joinCameraWiFi() async {
        #if os(iOS)
        guard !ssid.isEmpty else { notice = "Enter the camera's Wi-Fi name first (shown on the camera under Settings > Wi-Fi Settings)."; return }
        do {
            try await WiFiJoiner.join(ssid: ssid, passphrase: wifiPassword)
            notice = "iPadOS joined \(ssid). Checking the camera…"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await runDiagnostics()
        } catch {
            notice = "\(error)"
        }
        #else
        notice = "Joining a network from the app is only available on iPad."
        #endif
    }

    public func refreshUSBDevices() {
        usbDevices = ExternalCameraSource.availableDevices().map { ($0.uniqueID, $0.localizedName) }
        if usbDeviceID == nil { usbDeviceID = usbDevices.first?.id }
    }

    // 🐱 MARK: frames → UI

    private func updateOverlayConfig() {
        overlayBuilder.config = OverlayConfig(display: display, mmPerPixel: settings.effectiveMMPerPixel, method: settings.method,
                                              shakeEnabled: settings.shake.enabled, shakeReference: settings.shake.referenceROI,
                                              exclusions: settings.reflections.exclusions)
    }

    private func clearPreview() {
        videoDisplay.clear()
        live.set(nil)
        live.setVideoSize(nil)
        overlayBuilder.reset()
    }

    /// 🐱 Every camera frame, on the source thread → display layer (no main-thread work at all).
    nonisolated private func receivePreview(_ f: VideoFrame) {
        videoDisplay.show(f.pixelBuffer)
    }

    /// 🐱 Analysis results (analysis thread) → overlay (latest only) and numbers (≤ 4 per second).
    nonisolated private func receive(_ r: FrameResult) {
        let o = overlayBuilder.build(r)
        overlayPoster.post(o)
        let now = HostClock.now()
        if now - lastMetricsPost >= 0.25 {
            lastMetricsPost = now
            metricsPoster.post((r.metrics, o.status))
        }
    }

    // 🐱 MARK: save folder (security-scoped bookmark to a folder picked in the Files app)

    public func setExportFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() || FileManager.default.isWritableFile(atPath: url.path) else {
            notice = "The app cannot write to \(url.lastPathComponent). Choose another folder."
            return
        }
        exportFolderURL?.stopAccessingSecurityScopedResource()
        exportFolderURL = url
        exportFolderName = url.lastPathComponent
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "export.bookmark")
        }
    }

    public func clearExportFolder() {
        exportFolderURL?.stopAccessingSecurityScopedResource()
        exportFolderURL = nil
        exportFolderName = nil
        UserDefaults.standard.removeObject(forKey: "export.bookmark")
    }

    private func restoreExportFolder() {
        guard let data = UserDefaults.standard.data(forKey: "export.bookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        exportFolderURL = url
        exportFolderName = url.lastPathComponent
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "export.bookmark")
        }
    }

    // 🐱 MARK: diagnostics file (for remote troubleshooting of the camera link)

    public func saveDiagnostics() async {
        if sourceChoice == .aceProWiFi { await runDiagnostics() }
        var t: [String] = []
        let iso = ISO8601DateFormatter()
        t.append("LivePTV diagnostics \(iso.string(from: Date()))")
        t.append("system: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        t.append("source: \(sourceChoice.rawValue)  host \(host):\(port)  ssid \(ssid.isEmpty ? "-" : ssid)  password set: \(!wifiPassword.isEmpty)")
        t.append("wifi: \(wifiSummary)  inCameraSubnet: \(inCameraSubnet)  cameraReachable: \(cameraReachable.map(String.init) ?? "not checked")")
        t.append("interfaces: " + NetworkDiagnostics.ipv4Interfaces().map { "\($0.name) \($0.ipv4)/\($0.netmask)" }.joined(separator: ", "))
        t.append("connection: \(connectionState)")
        if let e = lastError { t.append("last error: \(e.description)"); t.append("hint: \(e.hint)") }
        if let a = autoConnectStatus { t.append("auto-connect: \(a)") }
        if let b = bssidCheck { t.append("access point: \(b.text)") }
        t.append("stream: \(streamParameters.map { "\($0.codec.rawValue) \($0.width)x\($0.height) \($0.nominalFPS ?? 0) fps [\($0.origin)]" } ?? "-")")
        t.append("camera: \(cameraInfoText ?? "-")")
        t.append(String(format: "metrics: delivered %d analysed %d camera %.2f fps analysis %.2f fps missing %d dropped %d decodeErrors %d",
                        metrics.framesDelivered, metrics.framesAnalyzed, metrics.sourceFPS ?? 0, metrics.processingFPS ?? 0,
                        metrics.streamGapFrames, metrics.analysisDrops, metrics.decodeErrors))
        t.append("")
        t.append("== network checks")
        for d in diagnostics { t.append("[\(d.status.rawValue)] \(d.title): \(d.detail)") }
        if let ace = source as? Insta360AcePro2WiFiSource {
            let st = ace.statistics()
            t.append("")
            t.append("== protocol: bytes \(st.bytesReceived) packets \(st.packetsReceived) decoded \(st.framesDecoded) timestampUnit \(ace.timestampUnit?.rawValue ?? "-")")
            t.append("packet types: " + st.packetTypes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
            for p in ace.packetLog.prefix(400) {
                t.append(String(format: "%.3f %@ %@ len=%d  %@", p.hostTime, p.direction, p.label, p.length, p.headHex))
            }
        }
        t.append("")
        t.append("== log")
        for l in logs { t.append("\(iso.string(from: l.time)) [\(l.level.rawValue)] \(l.message)") }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = sessionsDirectory.appendingPathComponent("diagnostics-\(stamp.string(from: Date())).txt")
        do {
            try t.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            lastDiagnosticsURL = url
        } catch {
            notice = "Could not save the diagnostics: \(error.localizedDescription)"
        }
    }

    // 🐱 MARK: analysis controls

    public func setROI(_ roi: PixelROI?) { settings.roi = roi }
    public func setShakeReference(_ roi: PixelROI?) { settings.shake.referenceROI = roi }

    /// 🐱 The drawn container outline; the frame size fixes the optical axis (frame centre) for the ray tracing.
    public func setContainerOutline(_ r: PixelROI, frameSize: CGSize) {
        var c = settings.container
        if c.shape == .none { c.shape = .cylinder }
        c.outline = r
        c.frameWidth = Int(frameSize.width)
        c.frameHeight = Int(frameSize.height)
        settings.container = c
        resetBackground()
    }

    public func addExclusion(_ r: PixelROI) {
        settings.reflections.exclusions.append(r)
    }

    public func clearExclusions() { settings.reflections.exclusions = [] }

    public func beginDrawing(_ target: EditTarget) {
        editTarget = target
        editingROI = true
    }

    public func resetBackground() { pipeline?.resetBackground() }

    // 🐱 MARK: recording

    public func startRecording() async {
        guard let source, let pipeline, recordingSince == nil else { return }
        do {
            var cam: [String: String] = [:]
            if let ace = source as? Insta360AcePro2WiFiSource, let info = ace.cameraInfo {
                cam["camera_type"] = info.cameraType
                cam["firmware"] = info.firmware
                cam["serial_number"] = info.serialNumber
            }
            let rec = try ExperimentRecorder(parent: sessionsDirectory, label: sessionLabel, source: source.info, settings: settings,
                                             streamParameters: streamParameters, cameraInfo: cam,
                                             archivePreviewStream: archivePreview && source.info.kind == .insta360WiFi)
            pipeline.attach(recorder: rec)
            recordingSince = Date()
            rec.log(.info, "recording started")
            if recordOnCamera, let ctl = source as? CameraRecordingControl {
                var cr = SessionMetadata.CameraRecording()
                cr.requestedHostTime = HostClock.now()
                do {
                    try await ctl.startCameraRecording()
                    cr.acknowledgedHostTime = HostClock.now()
                } catch {
                    cr.error = "\(error)"
                    notice = "The camera did not start its own recording: \(error). Preview analysis is still being recorded."
                }
                cameraRecording = cr
                rec.update(cameraRecording: cr)
            }
        } catch {
            notice = "Could not create the session folder: \(error.localizedDescription)"
        }
    }

    public func stopRecording() async {
        guard recordingSince != nil, let pipeline else { return }
        if var cr = cameraRecording, cr.acknowledgedHostTime != nil, let ctl = source as? CameraRecordingControl {
            cr.stopRequestedHostTime = HostClock.now()
            do {
                cr.cameraFile = try await ctl.stopCameraRecording()
                cr.stoppedHostTime = HostClock.now()
            } catch {
                cr.error = (cr.error.map { $0 + "; " } ?? "") + "stop: \(error)"
            }
            pipeline.recorder?.update(cameraRecording: cr)
        }
        cameraRecording = nil
        if let ace = source as? Insta360AcePro2WiFiSource {
            pipeline.recorder?.update(streamParameters: ace.streamParameters, timestampUnit: ace.timestampUnit?.rawValue, cameraInfo: nil)
        }
        let result = await pipeline.finishRecording()
        lastSessionURL = result?.folder
        lastEvaluation = result?.evaluation
        recordingSince = nil
        if lastEvaluation != nil { showEvaluation = true }
    }

    // 🐱 MARK: latency test

    public func runLatencyTest(changes: Int = 14, period: Double = 0.8) async {
        guard let pipeline, previewRunning, !latencyTestRunning else { return }
        latencyTestRunning = true
        latencyResultText = nil
        flashBright = false
        pipeline.latencyProbe.begin()
        try? await Task.sleep(nanoseconds: UInt64(period * 1e9))
        for _ in 0..<changes {
            flashBright.toggle()
            // 🐱 Recorded right after the state change; the panel updates at the next refresh (≤ 1 refresh later).
            pipeline.latencyProbe.screenChanged(toBright: flashBright)
            try? await Task.sleep(nanoseconds: UInt64(period * 1e9))
        }
        pipeline.latencyProbe.end()
        latencyTestRunning = false
        let res = pipeline.latencyProbe.results
        if res.isEmpty {
            latencyResultText = "No transitions detected. Point the camera at the iPad screen so the screen fills most of the analysis region, then retry."
        } else {
            let toResult = res.map(\.toResultMs).sorted(), toRecv = res.map(\.toReceiveMs).sorted()
            latencyResultText = String(format: "Screen → frame received: median %.0f ms (%.0f–%.0f). Screen → analysis result: median %.0f ms. %d transitions. Includes up to one display refresh.",
                                       toRecv[toRecv.count / 2], toRecv.first!, toRecv.last!, toResult[toResult.count / 2], res.count)
        }
    }
}
