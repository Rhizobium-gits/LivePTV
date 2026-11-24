import ImageIO
import Pipeline
import PTVCore
import SwiftUI

/// 🐱 Shown when a recording stops: verdict, warnings, key numbers, the session-averaged heatmap, and the report.
struct EvaluationView: View {
    let evaluation: SessionEvaluation
    let folder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var figure = "figure_summary.png"

    var body: some View {
        let e = evaluation
        NavigationStack {
            List {
                Section {
                    Text(e.verdict).font(.headline)
                        .foregroundStyle(e.verdict.hasPrefix("Good") ? .green : e.verdict.hasPrefix("Poor") ? .red : .orange)
                    ForEach(e.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").font(.callout)
                    }
                }
                Section("Time-averaged field") {
                    Picker("Figure", selection: $figure) {
                        Text("Field").tag("figure_summary.png")
                        Text("Profiles").tag("figure_profiles.png")
                        Text("Time").tag("figure_timeseries.png")
                        Text("On image").tag("overlay_on_image.png")
                    }
                    .pickerStyle(.segmented)
                    if let img = Self.load(folder.appendingPathComponent(figure)) {
                        Image(decorative: img, scale: 1).resizable().scaledToFit()
                    }
                    row("Valid cells", "\(e.field.validCells) / \(e.field.columns * e.field.rows) (\(f(e.field.coveragePercent, "%.0f")) %)")
                    row("Mean velocity", "u \(f(e.field.meanU)), v \(f(e.field.meanV)) \(e.field.speedUnit)")
                    row("Speed of mean field", "mean \(f(e.field.meanSpeedOfMeanField)), max \(f(e.field.maxSpeedOfMeanField)) \(e.field.speedUnit)")
                    row("Fluctuation RMS (median)", "\(f(e.field.fluctuationRMSMedian)) \(e.field.speedUnit)")
                    row("Uncertainty of mean (median)", e.field.relativeUncertaintyMedian.map { String(format: "%.1f %%", $0 * 100) } ?? "–")
                    row("Max |vorticity|", "\(f(e.field.vorticityMaxAbs)) 1/s")
                }
                if let d = e.diffusion {
                    Section("Brownian motion") {
                        row("D", "\(f(d.estimate.d)) ± \(f(d.estimate.standardError)) px²/s" + (d.dUm2PerS.map { String(format: " (%.3g µm²/s)", $0) } ?? ""))
                        row("Localisation noise", d.estimate.localizationNoisePx.map { String(format: "%.3f px", $0) } ?? "–")
                        if let size = d.stokesEinsteinDiameterNm { row("Stokes–Einstein diameter", String(format: "%.0f nm", size)) }
                        Text(d.interpretation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Measurement") {
                    row("Duration", "\(f(e.measurement.cameraTimeS, "%.1f")) s, \(e.measurement.framesAnalyzed) frames")
                    row("Frame rate", "camera \(f(e.measurement.measuredFPS, "%.2f")), analysis \(f(e.measurement.analysisFPS, "%.2f")) fps")
                    row("Missing / skipped frames", "\(e.measurement.missingFrames) / \(e.measurement.analysisDrops)")
                    row("Particles per frame", f(e.detection.particlesPerFrameMean, "%.0f"))
                    row("Velocity samples", "\(e.tracking.velocitySamples) (outliers \(f(e.tracking.outlierPercent, "%.1f")) %)")
                }
                Section("Files") {
                    ShareLink(item: folder.appendingPathComponent("report.html")) { Label("Share report (HTML)", systemImage: "doc.richtext") }
                    ShareLink(item: folder) { Label("Share whole session folder", systemImage: "folder") }
                    ShareLink(item: folder.appendingPathComponent("figure_summary.pdf")) { Label("Share field figure (PDF)", systemImage: "doc") }
                    Text("evaluation.json, mean_field.csv, profiles.csv and timeseries.csv hold all numbers; figure_*.pdf are vector graphics for papers.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Measurement evaluation")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 520, minHeight: 640)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }

    private func f(_ v: Double?, _ fmt: String = "%.3g") -> String { v.map { String(format: fmt, $0) } ?? "–" }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
