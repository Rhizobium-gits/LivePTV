import CameraKit
import Pipeline
import PTVCore
import SwiftUI

public struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showSessions = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            ControlPanel(model: model)
                .navigationTitle("LivePTV")
        } detail: {
            VStack(spacing: 0) {
                LiveView(model: model)
                MetricsBar(model: model, metrics: model.metricsModel)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { showSettings = true } label: { Label("Analysis settings", systemImage: "slider.horizontal.3") }
                    Button { showSessions = true } label: { Label("Sessions", systemImage: "folder") }
                }
            }
        }
        // 🐱 Join + connect automatically on launch, and again when coming back from Settings > Wi-Fi.
        .task { await model.autoConnect(reason: "launch") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.autoConnect(reason: "returned to app") } }
        }
        .sheet(isPresented: $showSettings) { AnalysisSettingsView(model: model) }
        .sheet(isPresented: $showSessions) { SessionsView(model: model) }
        .sheet(isPresented: $model.showEvaluation) {
            if let e = model.lastEvaluation, let folder = model.lastSessionURL {
                EvaluationView(evaluation: e, folder: folder)
            }
        }
        .overlay {
            // 🐱 Latency test: full-screen black/white flashes the camera must see.
            if model.latencyTestRunning {
                (model.flashBright ? Color.white : Color.black)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text("Latency test: keep the camera pointed at this screen")
                            .font(.caption).padding(8)
                            .background(.gray.opacity(0.5), in: Capsule())
                            .padding()
                    }
            }
        }
        .alert("Notice", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
    }
}

/// 🐱 Aspect-fit mapping between image pixels and view points.
struct FitTransform {
    let scale: CGFloat
    let origin: CGPoint
    let drawSize: CGSize

    init(image: CGSize, view: CGSize) {
        let s = (image.width > 0 && image.height > 0) ? min(view.width / image.width, view.height / image.height) : 1
        scale = s
        drawSize = CGSize(width: image.width * s, height: image.height * s)
        origin = CGPoint(x: (view.width - drawSize.width) / 2, y: (view.height - drawSize.height) / 2)
    }

    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
    func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
}
