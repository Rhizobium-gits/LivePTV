import SwiftUI

/// 🐱 Recorded sessions. On iPad they are also visible in the Files app (On My iPad > LivePTV > Sessions).
struct SessionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    Text("No sessions recorded yet.").foregroundStyle(.secondary)
                }
                ForEach(sessions, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.lastPathComponent).font(.headline)
                        Text(Self.summary(url)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            let report = url.appendingPathComponent("report.html")
                            if FileManager.default.fileExists(atPath: report.path) {
                                ShareLink(item: report) { Label("Report", systemImage: "doc.richtext") }
                            }
                            let preview = url.appendingPathComponent("preview.mp4")
                            if FileManager.default.fileExists(atPath: preview.path) {
                                Button {
                                    model.sourceChoice = .videoFile
                                    model.sourceChoiceChanged()
                                    model.videoFileURL = preview
                                    model.filePacing = .asFastAsPossible
                                    dismiss()
                                } label: { Label("Re-analyse preview", systemImage: "arrow.clockwise") }
                                    .disabled(model.isActive)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: reload)
        }
        .frame(minWidth: 420, minHeight: 400)
    }

    private func reload() {
        let dir = model.sessionsDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        sessions = items.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func summary(_ url: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return "\(files.count) files, \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
}
