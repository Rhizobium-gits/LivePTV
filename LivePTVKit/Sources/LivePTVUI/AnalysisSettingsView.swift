import Pipeline
import PTVCore
import SwiftUI

/// 🐱 All analysis parameters. Changes apply to the next frame; every value is also stored in session.json.
struct AnalysisSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mmPerPixelText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Interrogation windows", selection: $model.settings.piv.windowSizes) {
                        Text("128 → 64 → 32 px").tag([128, 64, 32])
                        Text("64 → 32 px").tag([64, 32])
                        Text("64 → 32 → 16 px").tag([64, 32, 16])
                        Text("32 → 16 px").tag([32, 16])
                    }
                    Picker("Overlap", selection: $model.settings.piv.overlap) {
                        Text("0 %").tag(0.0); Text("50 %").tag(0.5); Text("75 %").tag(0.75)
                    }
                    Toggle("Auto pair spacing", isOn: $model.settings.piv.autoPairSpacing)
                    if model.settings.piv.autoPairSpacing {
                        numberD("Target displacement (px)", $model.settings.piv.targetDisplacementPx, 0.5...8, 0.5)
                        Stepper("Max pair spacing: \(model.settings.piv.maxPairSpacing) frames", value: $model.settings.piv.maxPairSpacing, in: 2...30)
                    } else {
                        Stepper("Pair spacing: \(model.settings.piv.pairSpacing) frames", value: $model.settings.piv.pairSpacing, in: 1...30)
                    }
                    Picker("Analysis resolution", selection: $model.settings.pivResolution) {
                        ForEach(PIVResolution.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("Final-pass iterations: \(model.settings.piv.finalIterations)", value: $model.settings.piv.finalIterations, in: 1...4)
                    Toggle("Intensity capping (hurts faint particles)", isOn: $model.settings.piv.intensityCapping)
                    Stepper("Contrast normalisation radius: \(model.settings.piv.normalizationRadius) px", value: $model.settings.piv.normalizationRadius, in: 0...40)
                    Stepper("High-pass radius: \(model.settings.piv.highPassRadius) px", value: $model.settings.piv.highPassRadius, in: 0...30)
                    numberD("Min correlation", $model.settings.piv.minCorrelation, 0...0.9, 0.05)
                    numberD("Median test threshold", $model.settings.piv.validationThreshold, 1...10, 0.5)
                    Toggle("Replace invalid vectors (flagged)", isOn: $model.settings.piv.replaceInvalid)
                    Stepper("Save every \(model.settings.piv.saveEveryNthField)th field to CSV", value: $model.settings.piv.saveEveryNthField, in: 0...300, step: 5)
                    Toggle("Window deformation (follows velocity gradients)", isOn: $model.settings.piv.deformation)
                    if model.settings.piv.deformation {
                        Toggle("Smooth the predictor (lower noise; off: finer detail)", isOn: $model.settings.piv.predictorSmoothing)
                    }
                    Picker("Sub-pixel interpolation", selection: $model.settings.piv.windowInterpolation) {
                        Text("Lanczos 8-tap (accurate)").tag(PIVParameters.WindowInterpolation.lanczos4)
                        Text("Bilinear (fast, biased)").tag(PIVParameters.WindowInterpolation.bilinear)
                    }
                    Toggle("Per-vector uncertainty (correlation statistics)", isOn: $model.settings.piv.uncertainty)
                    Toggle(PIVEngine.gpuName.map { "Correlate on the GPU (\($0))" } ?? "Correlate on the GPU (not available)",
                           isOn: $model.settings.piv.useGPU)
                        .disabled(PIVEngine.gpuName == nil)
                    numberD("Max masked share of a window", $model.settings.piv.maxMaskedFraction, 0.1...0.9, 0.05)
                    Toggle("Ensemble correlation (µPIV, steady flow)", isOn: $model.settings.piv.ensemble.enabled)
                    if model.settings.piv.ensemble.enabled {
                        Stepper("Live average: \(model.settings.piv.ensemble.livePairs) pairs", value: $model.settings.piv.ensemble.livePairs, in: 10...600, step: 10)
                        numberD("Min peak ratio", $model.settings.piv.ensemble.minPeakRatio, 1.05...3, 0.05)
                    }
                } header: {
                    Text("PIV (cross-correlation)")
                } footer: {
                    Text("Aim for ~10 particle images per final window and displacements below a quarter of the window. Smaller final windows give finer spacing but more noise. Pair spacing > 1 helps slow flows. Ensemble correlation averages the correlation planes of many pairs (Meinhart et al. 2000): far more robust for faint, sparse or Brownian particles, but it gives the mean flow only. A recording sums every pair and adds ensemble_field.csv and figure_ensemble to the session; the pair spacing stays fixed while recording.")
                }
                Section {
                    Toggle("Remove camera shake", isOn: $model.settings.shake.enabled)
                    Picker("Camera motion model", selection: $model.settings.shake.model) {
                        ForEach(ShakeParameters.Model.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    numberD("Static threshold (px per frame)", $model.settings.shake.staticThresholdPxPerFrame, 0.02...1, 0.01)
                    Stepper("Learning pairs: \(model.settings.shake.warmupPairs)", value: $model.settings.shake.warmupPairs, in: 5...100, step: 5)
                } header: {
                    Text("Camera shake (PIV and PTV)")
                } footer: {
                    Text("Areas whose average motion stays near zero are treated as static background; their common motion in each pair is subtracted from every vector and particle step. Automatic picks per pair among shift, rotation + zoom (about any point, also outside the picture), shear (rolling shutter) and keystone (camera tilt), using only what the static areas can determine; when the camera keeps turning about one point (a swaying stand), that point is learned and shown. If too little background is found, nothing is corrected and the status says so. For very slow flows, draw a reference area on something fixed.")
                }
                reflectionSection
                containerSection
                Section("PTV detection") {
                    Picker("Particles are", selection: $model.settings.detector.polarity) {
                        Text("Bright on dark").tag(DetectorParameters.Polarity.brightOnDark)
                        Text("Dark on bright").tag(DetectorParameters.Polarity.darkOnBright)
                    }
                    Toggle("Background subtraction", isOn: $model.settings.detector.backgroundSubtraction)
                    Toggle("Smoothing (1-2-1)", isOn: $model.settings.detector.smoothing)
                    number("Threshold k (× noise σ above the background)", $model.settings.detector.thresholdK, 0.5...20, 0.5)
                    number("Minimum threshold (grey levels)", $model.settings.detector.minimumThreshold, 1...200, 1)
                    numberD("Minimum separation (px)", $model.settings.detector.minSeparation, 1...30, 0.5)
                    Stepper("Fit window radius: \(model.settings.detector.windowRadius) px", value: $model.settings.detector.windowRadius, in: 1...5)
                    Stepper("Min area: \(model.settings.detector.minArea) px", value: $model.settings.detector.minArea, in: 1...50)
                    Stepper("Max area: \(model.settings.detector.maxArea) px", value: $model.settings.detector.maxArea, in: 5...500, step: 5)
                    Picker("Sub-pixel estimator", selection: $model.settings.detector.subpixel) {
                        Text("3-point Gaussian").tag(DetectorParameters.Subpixel.gaussian3Point)
                        Text("Centroid").tag(DetectorParameters.Subpixel.centroid)
                    }
                }
                Section("Tracking") {
                    numberD("Max displacement per frame (px)", $model.settings.tracker.maxDisplacement, 1...100, 1)
                    numberD("Prediction radius (px)", $model.settings.tracker.predictionRadius, 0.5...30, 0.5)
                    Toggle("Predict new tracks from neighbours", isOn: $model.settings.tracker.neighborPrediction)
                    numberD("Neighbour radius (px)", $model.settings.tracker.neighborRadius, 5...200, 5)
                    Stepper("Bridge missed frames: \(model.settings.tracker.maxMissedFrames)", value: $model.settings.tracker.maxMissedFrames, in: 0...5)
                    numberD("Outlier threshold (median test)", $model.settings.tracker.outlierThreshold, 1...10, 0.5)
                }
                Section("Velocity field") {
                    numberD("Cell size (px)", $model.settings.field.cellSize, 8...256, 4)
                    numberD("Averaging window (s)", $model.settings.field.window, 0.1...30, 0.1)
                    Stepper("Min samples per cell: \(model.settings.field.minSamples)", value: $model.settings.field.minSamples, in: 1...100)
                    numberD("Outlier threshold (median test)", $model.settings.field.outlierThreshold, 1...10, 0.5)
                    numberD("Field update interval (s)", $model.settings.fieldInterval, 0.05...5, 0.05)
                }
                Section {
                    numberD("Grid cell size (px)", $model.settings.evaluation.cellSize, 4...256, 4)
                    Stepper("Min samples per cell: \(model.settings.evaluation.minSamplesPerCell)", value: $model.settings.evaluation.minSamplesPerCell, in: 2...1000, step: 5)
                    numberD("Fluid temperature (°C)", $model.settings.evaluation.temperatureC, -10...100, 0.5)
                    numberD("Fluid viscosity (mPa·s)", $model.settings.evaluation.viscosityMPaS, 0.1...100, 0.01)
                } header: {
                    Text("End-of-measurement evaluation")
                } footer: {
                    Text("When a recording stops, all velocity samples are averaged on this grid and evaluated (statistics, uncertainty, vorticity, Brownian diffusion). Temperature and viscosity are used for the Stokes–Einstein particle size; defaults are water at 20 °C.")
                }
                Section {
                    if let s = RefractionMap.cylinderScale(model.settings.container), model.settings.container.correctRefraction {
                        Text(String(format: "Length scale from the bottle silhouette: %.5f mm/px (overrides the value below)", s))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("mm per pixel (blank = pixels)", text: $mmPerPixelText)
                        .onSubmit { applyCalibration() }
                    TextField("Calibration note (target, plane, date)", text: $model.settings.calibration.note)
                    Toggle("Allow host arrival timing if the camera gives no timestamps", isOn: $model.settings.allowHostArrivalTiming)
                } header: {
                    Text("Calibration and timing")
                } footer: {
                    Text("mm per pixel comes from imaging a ruler or target in the measurement plane. Host arrival timing includes Wi-Fi jitter and is recorded as such.")
                }
            }
            .navigationTitle("Analysis settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { applyCalibration(); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Defaults") { model.settings = AnalysisSettings() }
                }
            }
            .onAppear { mmPerPixelText = model.settings.calibration.mmPerPixel.map { String($0) } ?? "" }
        }
        .frame(minWidth: 420, minHeight: 560)
    }

    // 🐱 MARK: scene corrections

    private var reflectionSection: some View {
        Section {
            Picker("Background removal", selection: $model.settings.reflections.background) {
                ForEach(ReflectionParameters.Background.allCases) { Text($0.title).tag($0) }
            }
            if model.settings.reflections.background != .off {
                Stepper("Background memory: \(model.settings.reflections.backgroundMemoryFrames) frames",
                        value: $model.settings.reflections.backgroundMemoryFrames, in: 30...3000, step: 30)
            }
            Toggle("Mask static glare", isOn: $model.settings.reflections.glareMasking)
            if model.settings.reflections.glareMasking {
                number("Glare level (grey)", $model.settings.reflections.glareLevel, 50...255, 5)
                number("…and above median background by", $model.settings.reflections.glareMargin, 5...200, 5)
            }
            Toggle("Mask moving glints (saturated blobs)", isOn: $model.settings.reflections.saturationMasking)
            if model.settings.reflections.saturationMasking {
                number("Saturation level (grey)", $model.settings.reflections.saturationLevel, 200...255, 1)
            }
            Stepper("Grow masks by \(model.settings.reflections.maskDilationPx) px", value: $model.settings.reflections.maskDilationPx, in: 0...20)
            HStack {
                Text("Exclusion regions: \(model.settings.reflections.exclusions.count)")
                Spacer()
                if !model.settings.reflections.exclusions.isEmpty {
                    Button("Clear", role: .destructive) { model.clearExclusions() }
                }
            }
        } header: {
            Text("Reflections and glare")
        } footer: {
            Text("The running mean of the last frames is subtracted from every frame: reflections on the glass, labels, scratches and uneven light are static, so they vanish while moving tracers or turbidity patterns remain (the first 30 frames are used raw while the mean builds up). Areas that stay very bright are masked as glare (no usable contrast there), as are saturated blobs that move (free-surface sparkle, bubbles). Camera motion is still measured on the raw frames. Add exclusions on the live image for anything else.")
        }
    }

    private static let wallMaterials: [(String, Double)] = [
        ("Borosilicate glass (Duran, Pyrex)", 1.474), ("Soda-lime glass", 1.52), ("Acrylic (PMMA)", 1.49),
        ("PET", 1.575), ("Polycarbonate", 1.586), ("Polystyrene", 1.59), ("Polypropylene", 1.49),
    ]
    private static let fluids: [(String, Double)] = [
        ("Water, 20 °C", 1.333), ("Seawater", 1.339), ("Ethanol", 1.361), ("Glycerol–water 50 %", 1.398),
        ("Glycerol", 1.473), ("Silicone oil", 1.403),
    ]

    private var containerSection: some View {
        Section {
            Picker("Container", selection: $model.settings.container.shape) {
                ForEach(ContainerGeometry.Shape.allCases) { Text($0.title).tag($0) }
            }
            let c = model.settings.container
            if c.shape != .none {
                if c.shape == .cylinder {
                    Picker("Axis in the image", selection: $model.settings.container.axis) {
                        Text("Vertical").tag(ContainerGeometry.Axis.vertical)
                        Text("Horizontal").tag(ContainerGeometry.Axis.horizontal)
                    }
                    numberField("Outer diameter (mm)", $model.settings.container.outerDiameterMM)
                }
                numberField("Wall thickness (mm)", $model.settings.container.wallThicknessMM)
                HStack {
                    numberField("Wall refractive index", $model.settings.container.wallIndex)
                    Menu("Material") {
                        ForEach(Self.wallMaterials, id: \.0) { m in Button("\(m.0)  \(String(format: "%.3f", m.1))") { model.settings.container.wallIndex = m.1 } }
                    }
                }
                HStack {
                    numberField("Fluid refractive index", $model.settings.container.fluidIndex)
                    Menu("Fluid") {
                        ForEach(Self.fluids, id: \.0) { m in Button("\(m.0)  \(String(format: "%.3f", m.1))") { model.settings.container.fluidIndex = m.1 } }
                    }
                }
                numberField(c.shape == .cylinder ? "Measurement plane from the axis, towards camera (mm)" : "Measurement plane behind the wall (mm)",
                            $model.settings.container.planeOffsetMM)
                Toggle("Camera distance known", isOn: Binding(
                    get: { model.settings.container.cameraDistanceMM != nil },
                    set: { model.settings.container.cameraDistanceMM = $0 ? (model.settings.container.cameraDistanceMM ?? 300) : nil }))
                if c.cameraDistanceMM != nil {
                    numberField(c.shape == .cylinder ? "Camera to bottle axis (mm)" : "Camera to outer wall (mm)",
                                Binding(get: { model.settings.container.cameraDistanceMM ?? 300 }, set: { model.settings.container.cameraDistanceMM = $0 }))
                }
                numberField("Excluded band inside the wall (mm)", $model.settings.container.wallMarginMM)
                if c.shape == .rectangular {
                    Toggle("mm/px was calibrated on the outer wall", isOn: $model.settings.container.calibratedAtWall)
                }
                Toggle("Correct refraction", isOn: $model.settings.container.correctRefraction)
                HStack {
                    Text(c.outline == nil ? "Outline not marked" : "Outline \(c.outline!.width) × \(c.outline!.height) px")
                    Spacer()
                    Button("Mark on image") { dismiss(); model.beginDrawing(.container) }
                }
                if let map = RefractionMap(geometry: c, calibrationMMPerPixel: model.settings.calibration.mmPerPixel) {
                    Text(map.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Container and refraction")
        } footer: {
            Text("A filled round bottle is a cylindrical lens: across its axis the fluid looks wider (≈ n × near the axis for a distant camera, much more near the walls), along the axis nothing changes. Every image point's camera ray is traced through air, wall and fluid to the measurement plane (Snell's law), so positions and velocities come out true, and the length scale follows from the outer diameter. Near the wall the image shows mirror images of tracers; that band is excluded. For flat tanks, calibrate in the measurement plane, or calibrate on the wall and give the camera distance.")
        }
    }

    private func numberField(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...4)))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
    }

    private func applyCalibration() {
        let t = mmPerPixelText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let v = Double(t), v > 0 { model.settings.calibration.mmPerPixel = v } else if t.isEmpty { model.settings.calibration.mmPerPixel = nil }
    }

    private func number(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ step: Float) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack { Text(title); Spacer(); Text(String(format: "%g", value.wrappedValue)).monospacedDigit() }
        }
    }

    private func numberD(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack { Text(title); Spacer(); Text(String(format: "%g", value.wrappedValue)).monospacedDigit() }
        }
    }
}
