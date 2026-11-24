import CameraKit
import Pipeline
import PTVCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// 🐱 Sidebar: source selection, the camera connection workflow with live status, recording, latency test.
struct ControlPanel: View {
    @ObservedObject var model: AppModel
    @State private var importing = false
    @State private var choosingFolder = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("Source") {
                Picker("Video source", selection: $model.sourceChoice) {
                    ForEach(SourceChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(model.isActive)
                .onChange(of: model.sourceChoice) { _, _ in model.sourceChoiceChanged() }
            }

            switch model.sourceChoice {
            case .aceProWiFi: cameraSection
            case .videoFile: fileSection
            case .synthetic: syntheticSection
            case .usbCamera: usbSection
            }

            Section("Session") {
                statusRow("Connection", model.connectionState.description, ok: model.connectionState.isActive)
                if let p = model.streamParameters {
                    statusRow("Stream", "\(p.codec.rawValue) \(p.width)×\(p.height)\(p.nominalFPS.map { String(format: " @ %.0f fps", $0) } ?? "")", ok: true)
                }
                if let err = model.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(err.description).foregroundStyle(.red)
                        Text(err.hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if model.previewRunning {
                        Button("Stop preview", role: .destructive) { Task { await model.stopPreview() } }
                    } else {
                        Button("Start preview") { Task { await model.startPreview() } }
                            .disabled(model.busy || (model.sourceChoice == .videoFile && model.videoFileURL == nil))
                    }
                    Spacer()
                    if model.isActive {
                        Button("Disconnect") { Task { await model.disconnect() } }
                    }
                }
                if model.busy { ProgressView().frame(maxWidth: .infinity) }
            }

            recordingSection
            latencySection
            analysisSection
            logSection
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            if case let .success(url) = result { model.videoFileURL = Self.importCopy(url) }
        }
    }

    // 🐱 MARK: Ace Pro 2

    private var cameraSection: some View {
        Group {
            Section("Connect the Ace Pro 2") {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Turn on the Ace Pro 2.")
                    step(2, "On the camera, swipe down and turn on Wi-Fi. Settings > Wi-Fi Settings shows the network name and password.")
                    step(3, "On the iPad, open Settings > Wi-Fi and join that network (or enter it below and tap Join). iPadOS may warn that it has no internet; stay connected.")
                    step(4, "Come back here and tap Connect. Allow Local Network access when asked.")
                }
                .font(.callout)
                TextField("Camera Wi-Fi name (SSID)", text: $model.ssid)
                    .autocorrectionDisabled()
                SecureField("Camera Wi-Fi password", text: $model.wifiPassword)
                TextField("Camera MAC address (optional, for checking)", text: $model.cameraMAC)
                    .autocorrectionDisabled()
                Toggle("Join and connect automatically when the app opens", isOn: $model.autoConnectOnLaunch)
                if model.presetLoaded {
                    Text("Camera details loaded from Camera.local.plist.").font(.caption).foregroundStyle(.secondary)
                }
                if let status = model.autoConnectStatus {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status).font(.callout)
                        Spacer()
                        if !model.isActive {
                            Button("Retry") { model.resumeAutoConnect() }.font(.callout)
                        }
                    }
                }
                #if os(iOS)
                Button("Join camera Wi-Fi") { Task { await model.joinCameraWiFi() } }
                    .disabled(model.ssid.isEmpty)
                Button("Open app settings (Local Network permission)") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.callout)
                #endif
            }
            Section("Camera status") {
                statusRow("Wi-Fi", model.wifiSummary, ok: model.inCameraSubnet)
                statusRow("Camera reachable", model.cameraReachable.map { $0 ? "Yes" : "No" } ?? "Not checked", ok: model.cameraReachable == true)
                if let b = model.bssidCheck {
                    statusRow("Access point", b.text, ok: b.ok == true)
                }
                if let info = model.cameraInfoText { statusRow("Camera", info, ok: true) }
                HStack {
                    Button("Connect") { Task { await model.connect() } }
                        .disabled(model.busy || model.connectionState.isActive)
                    Spacer()
                    Button(model.diagnosing ? "Checking…" : "Diagnose") { Task { await model.runDiagnostics() } }
                        .disabled(model.diagnosing)
                }
                ForEach(model.diagnostics) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(s.title, systemImage: s.status == .pass ? "checkmark.circle.fill" : s.status == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(s.status == .pass ? .green : s.status == .warn ? .orange : .red)
                        Text(s.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Save diagnostics file (for troubleshooting)") { Task { await model.saveDiagnostics() } }
                if let d = model.lastDiagnosticsURL {
                    ShareLink(item: d) { Label("Share \(d.lastPathComponent)", systemImage: "square.and.arrow.up") }.font(.callout)
                }
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Picker("Preferred preview", selection: $model.preferredResolution) {
                        ForEach([Insta360Messages.PreviewResolution.res1920x1080p30, .res1280x720p30, .res1440x720p30], id: \.self) {
                            Text("\($0.size.width)×\($0.size.height) @ \(Int($0.size.fps))").tag($0)
                        }
                    }
                    Toggle("Low-latency assembly (falls back automatically if frames arrive split)", isOn: $model.lowLatencyAssembly)
                    TextField("Camera address", text: $model.host)
                    TextField("Port", text: $model.port)
                }
                .disabled(model.isActive)
            }
        }
    }

    // 🐱 MARK: other sources

    private var fileSection: some View {
        Section("Video file") {
            Button(model.videoFileURL == nil ? "Choose video…" : "Change video…") { importing = true }
                .disabled(model.isActive)
            if let u = model.videoFileURL { Text(u.lastPathComponent).font(.caption) }
            Picker("Playback", selection: $model.filePacing) {
                Text("Real time (rehearse live)").tag(VideoFileSource.Pacing.realTime)
                Text("Every frame (offline analysis)").tag(VideoFileSource.Pacing.asFastAsPossible)
            }
            .disabled(model.isActive)
        }
    }

    private var syntheticSection: some View {
        Section("Test pattern") {
            Picker("Flow", selection: $model.syntheticChoice) {
                ForEach(SyntheticChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(model.isActive)
            Text("Synthetic particle images with an exactly known velocity field, for checking the analysis without a camera.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var usbSection: some View {
        Section("USB camera") {
            Picker("Device", selection: $model.usbDeviceID) {
                ForEach(model.usbDevices, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Resolution", selection: $model.usbResolution) {
                ForEach(USBResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(model.isActive)
            Button("Refresh devices") { model.refreshUSBDevices() }
            Text("Needs a USB-C iPad with iPadOS 17 or later. The Ace Pro 2's Webcam mode is documented for computers only; whether iPadOS accepts it has not been verified.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.refreshUSBDevices() }
    }

    // 🐱 MARK: recording, latency, analysis, log

    private var recordingSection: some View {
        Section("Recording") {
            HStack {
                Label(model.exportFolderName.map { "Save to: \($0)" } ?? "Save to: app storage (use Share to export)",
                      systemImage: "folder")
                    .font(.callout)
                Spacer()
                Button(model.exportFolderName == nil ? "Choose folder…" : "Change…") { choosingFolder = true }
                    .disabled(model.recordingSince != nil)
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { model.setExportFolder(url) }
            }
            if model.exportFolderName != nil {
                Button("Use app storage instead", role: .destructive) { model.clearExportFolder() }
                    .font(.caption).disabled(model.recordingSince != nil)
            }
            TextField("Session label", text: $model.sessionLabel)
            Toggle("Save the received preview stream (bit-exact)", isOn: $model.archivePreview)
                .disabled(model.recordingSince != nil)
            if model.sourceChoice == .aceProWiFi {
                Toggle("Also record on the camera's card (experimental)", isOn: $model.recordOnCamera)
                    .disabled(model.recordingSince != nil)
            }
            if model.recordingSince == nil {
                Button("Start recording") { Task { await model.startRecording() } }
                    .disabled(!model.previewRunning)
            } else {
                Button("Stop recording", role: .destructive) { Task { await model.stopRecording() } }
            }
            if let u = model.lastSessionURL {
                Text("Saved: \(u.lastPathComponent)").font(.caption)
                if model.lastEvaluation != nil {
                    Button("Show evaluation of last recording") { model.showEvaluation = true }
                }
            }
            Text("The live preview is lower quality than the camera's own recording. Keep the camera recording as the high-quality source when the measurement matters.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var latencySection: some View {
        Section("Latency") {
            Button(model.latencyTestRunning ? "Running…" : "Run screen-flash test") { Task { await model.runLatencyTest() } }
                .disabled(!model.previewRunning || model.latencyTestRunning)
            Text("Point the camera at this screen. The screen flashes black/white and the app measures how long each change takes to appear in the analysed frames.")
                .font(.caption).foregroundStyle(.secondary)
            if let r = model.latencyResultText { Text(r).font(.callout) }
        }
    }

    private var analysisSection: some View {
        Section("Analysis") {
            Picker("Method", selection: $model.settings.method) {
                ForEach(AnalysisMethod.allCases) { Text($0.title).tag($0) }
            }
            if model.settings.method == .piv {
                Toggle("Auto pair spacing (catch slow, small motion)", isOn: $model.settings.piv.autoPairSpacing)
                if !model.settings.piv.autoPairSpacing {
                    Stepper("Pair spacing: \(model.settings.piv.pairSpacing) frame\(model.settings.piv.pairSpacing == 1 ? "" : "s")",
                            value: $model.settings.piv.pairSpacing, in: 1...30)
                }
                Picker("Analysis resolution", selection: $model.settings.pivResolution) {
                    ForEach(PIVResolution.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Ensemble correlation (steady flow, faint particles)", isOn: $model.settings.piv.ensemble.enabled)
                if model.settings.piv.ensemble.enabled {
                    Text("Averages correlation planes over the last \(model.settings.piv.ensemble.livePairs) pairs (live) and over the whole recording. Shows the mean flow; \"Reset background\" restarts the live average.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Remove camera shake", isOn: $model.settings.shake.enabled)
                if model.settings.shake.enabled {
                    HStack {
                        Button("Draw static reference area") { model.beginDrawing(.shakeReference) }
                        if model.settings.shake.referenceROI != nil {
                            Spacer()
                            Button("Clear", role: .destructive) { model.setShakeReference(nil) }
                        }
                    }
                    .font(.callout)
                    Text(model.settings.shake.referenceROI == nil
                         ? "Automatic: areas that have not moved are used as the reference. Optional: draw a box on a wall or ruler."
                         : "Using the drawn reference area.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LiveStatusLine(metrics: model.metricsModel, previewRunning: model.previewRunning)
            } else {
                Text("PTV tracks individual particles; needed for Brownian diffusion / particle size.").font(.caption).foregroundStyle(.secondary)
            }
            sceneCorrectionControls
            Toggle("Particles", isOn: $model.display.particles)
            Toggle("Track tails", isOn: $model.display.tails)
            Toggle("Velocity field", isOn: $model.display.vectors)
            Toggle("Auto arrow length", isOn: $model.display.autoArrowScale)
            Picker("Heatmap", selection: $model.display.heatmap) {
                ForEach(HeatmapQuantity.allCases) { Text($0.title).tag($0) }
            }
            if model.display.heatmap != .off {
                HStack {
                    Text("Heatmap opacity")
                    Slider(value: $model.display.heatmapOpacity, in: 0.1...1)
                }
            }
            if !model.display.autoArrowScale {
                HStack {
                    Text("Arrow length")
                    Slider(value: $model.display.vectorSeconds, in: 0.05...10)
                    Text(String(format: "%.2f s", model.display.vectorSeconds)).monospacedDigit().font(.caption)
                }
            }
            Button("Draw analysis region") { model.beginDrawing(.analysisRegion) }
            HStack {
                Button("Full frame") { model.setROI(nil) }
                Spacer()
                Button("Reset background") { model.resetBackground() }
            }
        }
    }

    /// 🐱 Realistic-scene corrections: background removal, container (wall mask + refraction), exclusions.
    @ViewBuilder private var sceneCorrectionControls: some View {
        Picker("Background removal", selection: $model.settings.reflections.background) {
            ForEach(ReflectionParameters.Background.allCases) { Text($0.title).tag($0) }
        }
        Picker("Container", selection: $model.settings.container.shape) {
            ForEach(ContainerGeometry.Shape.allCases) { Text($0.title).tag($0) }
        }
        if model.settings.container.shape != .none {
            Button(model.settings.container.outline == nil ? "Mark container outline" : "Re-mark container outline") { model.beginDrawing(.container) }
            Text(containerSummary).font(.caption).foregroundStyle(model.settings.container.isConfigured ? Color.secondary : Color.orange)
        }
        HStack {
            Button("Add exclusion") { model.beginDrawing(.exclusion) }
            if !model.settings.reflections.exclusions.isEmpty {
                Spacer()
                Button("Clear \(model.settings.reflections.exclusions.count)", role: .destructive) { model.clearExclusions() }
            }
        }
        Toggle("Show masked areas", isOn: $model.display.showMask)
    }

    private var containerSummary: String {
        let c = model.settings.container
        guard c.isConfigured else {
            return "Drag across the outer edges of the container on the image. Diameter, wall and refractive indices: Analysis settings > Container."
        }
        if c.shape == .cylinder, let s = RefractionMap.cylinderScale(c) {
            return String(format: "⌀%.1f mm bottle, %.4f mm/px from its silhouette; refraction %@.", c.outerDiameterMM, s,
                          c.correctRefraction ? "corrected" : "NOT corrected")
        }
        return c.calibratedAtWall ? "Flat tank, wall calibration corrected to the measurement plane." : "Flat tank: wall band masked (calibrate in the measurement plane)."
    }

    private var logSection: some View {
        Section("Log") {
            if model.logs.isEmpty { Text("No messages").foregroundStyle(.secondary) }
            ForEach(model.logs.suffix(40).reversed()) { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    Text(e.message).font(.caption).foregroundStyle(e.level == .error ? .red : e.level == .warning ? .orange : .primary)
                }
            }
        }
    }

    // 🐱 MARK: helpers

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").bold()
            Text(text)
        }
    }

    private func statusRow(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? .green : .secondary)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).font(.callout)
        }
    }

    /// 🐱 Copy a picked file into the app's temporary folder (security-scoped URLs expire).
    static func importCopy(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
