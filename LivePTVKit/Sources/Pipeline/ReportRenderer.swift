import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PTVCore

/// 🐱 Turns a session evaluation into files: heatmap PNGs, mean_field.csv, speed_histogram.csv, report.html.
enum ReportRenderer {
    // 🐱 MARK: images

    /// 🐱 Heatmap over the (dimmed) last frame, optional mean-velocity arrows, colour bar with range and unit.
    static func heatmapPNG(layer: HeatmapLayer, background: CGImage?, frameSize: CGSize, title: String,
                           arrows: [CellStatistics]? = nil) -> Data? {
        let scale = min(1, 1600 / max(frameSize.width, 1))
        let imgW = Int((frameSize.width * scale).rounded()), imgH = Int((frameSize.height * scale).rounded())
        let barW = 110, titleH = 44
        let W = imgW + barW, H = imgH + titleH
        guard imgW > 0, imgH > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpaceCreateDeviceRGB(),
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        if let bg = background {
            ctx.draw(bg, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
            ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        } else {
            ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        }
        // 🐱 image coordinates (y down) for the field
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(imgH))
        ctx.scaleBy(x: scale, y: -scale)
        let g = layer.grid
        for k in 0..<g.count {
            guard let c = layer.rgb(at: k) else { continue }
            ctx.setFillColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 0.8))
            let i = k % g.columns, j = k / g.columns
            ctx.fill(CGRect(x: g.originX + Double(i) * g.cellSize, y: g.originY + Double(j) * g.cellSize, width: g.cellSize, height: g.cellSize))
        }
        if let arrows {
            let maxSpeed = arrows.filter(\.valid).map(\.speedOfMean).max() ?? 0
            if maxSpeed > 0 {
                let len = g.cellSize * 0.9 / maxSpeed
                ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.85))
                ctx.setLineWidth(max(1.2, 1.6 / scale))
                for c in arrows where c.valid {
                    let ex = c.x + c.meanU * len, ey = c.y + c.meanV * len
                    ctx.move(to: CGPoint(x: c.x, y: c.y))
                    ctx.addLine(to: CGPoint(x: ex, y: ey))
                    let l = hypot(ex - c.x, ey - c.y)
                    if l > 3 {
                        let ux = (ex - c.x) / l, uy = (ey - c.y) / l, hd = min(g.cellSize * 0.25, l * 0.4)
                        ctx.move(to: CGPoint(x: ex, y: ey)); ctx.addLine(to: CGPoint(x: ex - hd * (ux - 0.5 * uy), y: ey - hd * (uy + 0.5 * ux)))
                        ctx.move(to: CGPoint(x: ex, y: ey)); ctx.addLine(to: CGPoint(x: ex - hd * (ux + 0.5 * uy), y: ey - hd * (uy - 0.5 * ux)))
                    }
                }
                ctx.strokePath()
            }
        }
        ctx.restoreGState()

        // 🐱 colour bar (y up in this coordinate system)
        let bx = CGFloat(imgW + 20), by: CGFloat = 30, bh = CGFloat(imgH) - 60
        let steps = 100
        for s in 0..<steps {
            let c = layer.quantity.colormap.rgb(Double(s) / Double(steps - 1))
            ctx.setFillColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
            ctx.fill(CGRect(x: bx, y: by + bh * CGFloat(s) / CGFloat(steps), width: 24, height: bh / CGFloat(steps) + 1))
        }
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: bx, y: by, width: 24, height: bh))
        draw(text(layer.hi), in: ctx, at: CGPoint(x: bx + 28, y: by + bh - 6), size: 13)
        draw(text((layer.lo + layer.hi) / 2), in: ctx, at: CGPoint(x: bx + 28, y: by + bh / 2 - 6), size: 13)
        draw(text(layer.lo), in: ctx, at: CGPoint(x: bx + 28, y: by - 6), size: 13)
        draw(layer.unit, in: ctx, at: CGPoint(x: bx, y: by + bh + 10), size: 13)
        draw(title, in: ctx, at: CGPoint(x: 12, y: CGFloat(imgH) + 14), size: 18)

        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func text(_ v: Double) -> String {
        let a = abs(v)
        if a == 0 { return "0" }
        if a >= 1000 || a < 0.01 { return String(format: "%.2e", v) }
        return String(format: a >= 100 ? "%.0f" : a >= 10 ? "%.1f" : "%.2f", v)
    }

    private static func draw(_ s: String, in ctx: CGContext, at p: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    // 🐱 MARK: tables

    static func meanFieldCSV(_ cells: [CellStatistics], mmPerPixel: Double?) -> String {
        let f: (Double) -> String = { $0.isFinite ? String(format: "%.6g", $0) : "" }
        let o: (Double?) -> String = { $0.map(f) ?? "" }
        var rows = ["i,j,x_px,y_px,samples,valid,mean_u_px_s,mean_v_px_s,speed_of_mean_px_s,mean_speed_px_s,std_u_px_s,std_v_px_s,cov_uv_px2_s2,se_u_px_s,se_v_px_s,relative_uncertainty,turbulence_intensity,vorticity_1_s,divergence_1_s,mean_u_mm_s,mean_v_mm_s,speed_of_mean_mm_s,x_mm,y_mm,sigma_single_px_s,rms_fluctuation_noise_corrected_px_s"]
        for c in cells {
            rows.append([String(c.i), String(c.j), f(c.x), f(c.y), String(c.count), c.valid ? "1" : "0", f(c.meanU), f(c.meanV),
                         f(c.speedOfMean), f(c.meanSpeed), f(c.stdU), f(c.stdV), f(c.covUV), f(c.standardErrorU), f(c.standardErrorV),
                         o(c.relativeUncertainty), o(c.turbulenceIntensity), o(c.vorticity), o(c.divergence),
                         o(mmPerPixel.map { c.meanU * $0 }), o(mmPerPixel.map { c.meanV * $0 }), o(mmPerPixel.map { c.speedOfMean * $0 }),
                         o(mmPerPixel.map { c.x * $0 }), o(mmPerPixel.map { c.y * $0 }), o(c.measurementUncertainty), o(c.noiseCorrectedFluctuationRMS)]
                .joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// 🐱 Ensemble-correlation field: displacement per pair and velocity per window, peak height / ratio, pairs.
    static func ensembleCSV(_ e: EnsembleField, mmPerPixel: Double?) -> String {
        let f: (Double) -> String = { $0.isFinite ? String(format: "%.6g", $0) : "" }
        let fl = e.field
        let inv = fl.dt > 0 ? 1 / fl.dt : 0
        var head = "i,j,x_px,y_px,dx_px_per_pair,dy_px_per_pair,u_px_s,v_px_s,speed_px_s"
        if mmPerPixel != nil { head += ",u_mm_s,v_mm_s,speed_mm_s" }
        head += ",peak_correlation,peak_ratio,pairs,status"
        var rows = [head]
        for k in 0..<fl.count {
            let u = fl.dx[k] * inv, v = fl.dy[k] * inv
            var r = [String(k % fl.columns), String(k / fl.columns), f(fl.x(k)), f(fl.y(k)), f(fl.dx[k]), f(fl.dy[k]), f(u), f(v), f(hypot(u, v))]
            if let mm = mmPerPixel { r += [f(u * mm), f(v * mm), f(hypot(u, v) * mm)] }
            let st: String
            switch fl.status[k] {
            case .valid: st = "valid"
            case .replaced: st = "replaced"
            case .invalid: st = "invalid"
            case .masked: st = "masked"
            }
            r += [f(Double(fl.correlation[k])), f(Double(e.peakRatio[k])), String(e.pairs[k]), st]
            rows.append(r.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n" + String(format: "# ensemble correlation over %d pairs, %d frames apart, mean pair interval %.6g s\n", e.totalPairs, e.pairSpacing, fl.dt)
    }

    static func histogramCSV(_ values: [Double], bins: Int = 40, unit: SpeedUnit) -> String {
        let v = values.map { $0 * unit.factor }.sorted()
        guard let lo = v.first, let hi = v.last, hi > lo else { return "bin_lo,bin_hi,count,fraction\n" }
        let top = v[min(v.count - 1, Int(Double(v.count - 1) * 0.995))]
        let w = max(top - lo, 1e-12) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for x in v { counts[min(bins - 1, max(0, Int((x - lo) / w)))] += 1 }
        var rows = ["bin_lo_\(unit.label.replacingOccurrences(of: "/", with: "_")),bin_hi,count,fraction"]
        for b in 0..<bins {
            rows.append(String(format: "%.6g,%.6g,%d,%.6f", lo + Double(b) * w, lo + Double(b + 1) * w, counts[b], Double(counts[b]) / Double(v.count)))
        }
        return rows.joined(separator: "\n") + "\n" + "# reservoir sample of \(v.count) speeds; last bin includes values above the 99.5th percentile\n"
    }

    /// 🐱 Legacy VTK structured-points file of the mean field (opens in ParaView / VisIt). Lengths and velocities in
    /// 🐱 mm and mm/s when calibrated, otherwise px and px/s; y points down (image convention); invalid cells are NaN.
    static func vtk(_ cells: [CellStatistics], grid g: GridGeometry, mmPerPixel: Double?, title: String) -> String {
        let L = mmPerPixel ?? 1
        let f: (Double) -> String = { $0.isFinite ? String(format: "%.7g", $0) : "nan" }
        var s = "# vtk DataFile Version 3.0\n\(title.replacingOccurrences(of: "\n", with: " ").prefix(200)) (units: \(mmPerPixel == nil ? "px, px/s" : "mm, mm/s"); y down)\nASCII\nDATASET STRUCTURED_POINTS\n"
        s += "DIMENSIONS \(g.columns) \(g.rows) 1\n"
        s += "ORIGIN \(f((g.originX + g.cellSize / 2) * L)) \(f((g.originY + g.cellSize / 2) * L)) 0\n"
        s += "SPACING \(f(g.cellSize * L)) \(f(g.cellSize * L)) 1\n"
        s += "POINT_DATA \(g.count)\n"
        func scalars(_ name: String, _ value: (CellStatistics) -> Double?) {
            s += "SCALARS \(name) double 1\nLOOKUP_TABLE default\n"
            s += cells.map { c in c.valid ? f(value(c) ?? .nan) : "nan" }.joined(separator: "\n") + "\n"
        }
        s += "VECTORS velocity double\n"
        s += cells.map { c in c.valid ? "\(f(c.meanU * L)) \(f(c.meanV * L)) 0" : "nan nan nan" }.joined(separator: "\n") + "\n"
        scalars("speed", { $0.speedOfMean * L })
        scalars("std_u", { $0.stdU * L })
        scalars("std_v", { $0.stdV * L })
        scalars("reynolds_stress_uv", { $0.covUV * L * L })
        scalars("standard_error_u", { $0.standardErrorU * L })
        scalars("standard_error_v", { $0.standardErrorV * L })
        scalars("vorticity", { $0.vorticity })
        scalars("divergence", { $0.divergence })
        scalars("sigma_single_vector", { $0.measurementUncertainty.map { $0 * L } })
        scalars("samples", { Double($0.count) })
        return s
    }

    /// 🐱 A methods paragraph describing exactly what was done, with the numbers of this session (for papers / notes).
    /// 🐱 One sentence on how camera motion was removed: model(s), and the pivot when one was found.
    static func cameraMotionSentence(_ e: SessionEvaluation, settings s: AnalysisSettings) -> String {
        let names = ["translation": "a translation", "similarity": "a similarity transform (shift, rotation, zoom)",
                     "affine": "an affine transform (adds shear and stretch)", "perspective": "a linearised perspective transform (adds keystone)",
                     "pivot": "a rotation and zoom about a fixed point"]
        var t: String
        if s.shake.model == .auto {
            let used = (e.cameraMotion?.models ?? [:]).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            t = "Camera motion was removed per pair: a translation, similarity, affine or linearised perspective model (or a rotation about the learned pivot), chosen per pair by the Bayesian information criterion among the models the static background could determine, was fitted to windows identified as static background (pairs per model: \(used.isEmpty ? "none" : used))."
        } else {
            t = "Camera motion was removed per pair by fitting \(names[s.shake.model.rawValue] ?? "a similarity transform") to windows identified as static background."
        }
        if let c = e.cameraMotion, let x = c.pivotXPx, let y = c.pivotYPx, let r2 = c.pivotRSquared {
            t += String(format: " The motion turned about a point at (%.0f, %.0f) px%@ (rotation and zoom about it explain %.0f %% of the fitted shifts; RMS rotation %.2f mrad per pair).",
                        x, y, c.pivotInsideFrame == false ? ", outside the image" : "", r2 * 100, c.rotationRMSMrad)
        }
        return t
    }

    static func methodsText(_ e: SessionEvaluation, settings s: AnalysisSettings, rectified: Bool) -> String {
        var parts: [String] = []
        let p = s.piv
        let fps = e.measurement.measuredFPS.map { String(format: "%.2f fps", $0) } ?? "the camera frame rate"
        if e.method == "piv" {
            var t = "Velocity fields were obtained by particle image velocimetry (LivePTV) from \(e.measurement.framesAnalyzed) frames recorded at \(fps)"
            t += String(format: " (%.1f s of camera time; velocities use camera timestamps).", e.measurement.cameraTimeS)
            parts.append(t)
            let rp = s.reflections
            if rp.background != .off {
                parts.append("Each frame first had a temporal background removed (\(rp.background == .mean ? "running mean" : rp.background == .minimum ? "running lower envelope" : "running upper envelope") with a memory of \(rp.backgroundMemoryFrames) frames), which suppresses static reflections, labels and scratches on the container.")
            }
            var masks: [String] = []
            if rp.glareMasking { masks.append(String(format: "static glare (background ≥ max(%.0f, median + %.0f) grey levels)", rp.glareLevel, rp.glareMargin)) }
            if rp.saturationMasking { masks.append(String(format: "moving saturated glints (≥ %.0f grey levels)", rp.saturationLevel)) }
            if !rp.exclusions.isEmpty { masks.append("\(rp.exclusions.count) user-defined exclusion region\(rp.exclusions.count == 1 ? "" : "s")") }
            if s.container.isConfigured { masks.append(String(format: "everything outside the fluid and a %.1f mm band inside the container wall", s.container.wallMarginMM)) }
            if !masks.isEmpty {
                parts.append("Pixels belonging to " + masks.joined(separator: ", ") + String(format: " were masked (dilated by %d px); interrogation windows more than %.0f %% masked were not evaluated.", rp.maskDilationPx, p.maxMaskedFraction * 100))
            }
            let interp = p.windowInterpolation == .lanczos4 ? "8-tap Lanczos (windowed-sinc)" : "bilinear"
            let scheme = p.deformation
                ? String(format: "multi-pass with iterative image deformation (Scarano 2002): both frames resampled symmetrically by the previous pass's field, interpolated between vectors by cubic convolution%@, with %@ image interpolation", p.predictorSmoothing ? " after a 3 × 3 binomial filter (Schrijer & Scarano 2008)" : "", interp)
                : String(format: "multi-pass with symmetric sub-pixel window offset, %@ interpolation of the shifted windows", interp)
            parts.append(String(format: "Images were normalised by local contrast (box radius %d px). Cross-correlation was computed by FFT in %@ px interrogation windows (%@, %d final iterations, %.0f %% overlap), with a 3-point Gaussian peak fit corrected for the window-overlap bias (Westerweel 1997). Vectors with a normalised correlation below %.2f or failing the normalised median test (threshold %.1f, ε = %.2f px; Westerweel & Scarano 2005) were rejected%@.",
                                p.normalizationRadius, p.windowSizes.map(String.init).joined(separator: "→"),
                                scheme, p.finalIterations, p.overlap * 100,
                                p.minCorrelation, p.validationThreshold, p.validationEpsilonPx, p.replaceInvalid ? " and replaced by the median of their neighbours (excluded from statistics)" : ""))
            if let q = e.piv {
                var t = String(format: "%.1f %% of the evaluated vectors were valid", q.validPercent)
                if let m = q.maskedPercent, m > 0 { t += String(format: " (%.1f %% of windows masked)", m) }
                t += "."
                if let u = q.uncertaintyMedianPx {
                    t += String(format: " The random uncertainty of single vectors, estimated from correlation statistics (Wieneke 2015), had a median of %.3f px per pair", u)
                    t += q.uncertaintyP95Px.map { String(format: " (95th percentile %.3f px).", $0) } ?? "."
                }
                if let d = q.particleImageDiameterPx { t += String(format: " The particle-image diameter inferred from the correlation-peak width was %.1f px", d) + (q.peakLockingIndex.map { String(format: " (peak-locking index %.2f).", $0) } ?? ".") }
                parts.append(t)
                if q.shakeCompensation { parts.append(cameraMotionSentence(e, settings: s)) }
                if let en = q.ensemble { parts.append("In addition, an ensemble correlation (Meinhart, Wereley & Santiago 2000) averaged the correlation planes of \(en.pairs) pairs.") }
            }
        } else {
            parts.append("Particles were detected and tracked (LivePTV PTV) in \(e.measurement.framesAnalyzed) frames recorded at \(fps).")
            if e.cameraMotion != nil { parts.append(cameraMotionSentence(e, settings: s) + " The camera motion between the two frames of every particle step was subtracted at the particle's position; it was measured by cross-correlating 64-px windows of the raw frames.") }
        }
        if let c = e.corrections, c.refractionCorrected {
            parts.append("Refraction by the container was corrected by tracing the camera ray of every image point through the wall into the measurement plane (Snell's law in 3-D; \(c.container)). Displacements were mapped end to end, and the time-averaged field was resampled on a regular grid in true plane coordinates\(rectified ? "" : " (not possible for this session)").")
        }
        if let mm = e.mmPerPixel {
            parts.append(String(format: "The length scale was %.5g mm per pixel (%@).", mm, e.corrections?.lengthScaleSource ?? "calibration"))
        }
        let f = e.field
        parts.append(String(format: "Statistics were accumulated on a %d × %d grid (%.0f px cells); %d cells had at least %d samples. The statistical uncertainty of the mean is the standard error of the samples in each cell (median %.1f %% of the local speed).",
                            f.columns, f.rows, f.cellSizePx, f.validCells, s.evaluation.minSamplesPerCell, (f.relativeUncertaintyMedian ?? .nan) * 100))
        return parts.joined(separator: " ")
    }

    // 🐱 MARK: HTML

    static func html(_ e: SessionEvaluation, label: String, images: [(title: String, file: String, png: Data)], methods: String? = nil) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        func n(_ v: Double?, _ fmt: String = "%.3g") -> String { v.map { String(format: fmt, $0) } ?? "–" }
        func row(_ k: String, _ v: String) -> String { "<tr><th>\(esc(k))</th><td>\(esc(v))</td></tr>" }
        let m = e.measurement, d = e.detection, t = e.tracking, f = e.field
        var sections: [String] = []
        sections.append("""
        <h2>Measurement</h2><table>
        \(row("Camera time", n(m.cameraTimeS, "%.1f s")))\(row("Frames analysed", "\(m.framesAnalyzed)"))
        \(row("Camera frame rate", n(m.measuredFPS, "%.2f fps")))\(row("Analysis rate", n(m.analysisFPS, "%.2f fps")))
        \(row("Missing camera frames", "\(m.missingFrames) (\(n(m.missingFramePercent, "%.2f")) %)"))
        \(row("Frames skipped by analysis", "\(m.analysisDrops) (\(n(m.analysisDropPercent, "%.2f")) %)"))
        \(row("Decode errors", "\(m.decodeErrors)"))
        \(row("Arrival → result", "\(n(m.receiveToResultMedianMs, "%.1f")) ms median, \(n(m.receiveToResultP95Ms, "%.1f")) ms p95"))
        \(row("Timestamp quality", m.timestampQuality.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")))
        </table>
        """)
        sections.append("""
        <h2>Detection and tracking</h2><table>
        \(row("Particles per frame", "mean \(n(d.particlesPerFrameMean, "%.0f")), median \(n(d.particlesPerFrameMedian, "%.0f")), range \(d.particlesPerFrameMin)–\(d.particlesPerFrameMax)"))
        \(row("Particle-image density", "\(n(d.densityPer10kPx, "%.1f")) per 10⁴ px²" + (d.densityPerMM2.map { String(format: ", %.3g per mm²", $0) } ?? "")))
        \(row("Velocity samples", "\(t.velocitySamples) (outliers \(t.outlierSamples), \(n(t.outlierPercent, "%.2f")) %)"))
        \(row("Track length (observations)", "median \(n(t.trackLengthMedian, "%.0f")), p90 \(n(t.trackLengthP90, "%.0f")), \(t.tracksFinished) tracks"))
        \(row("Displacement per frame", "median \(n(t.displacementMedianPx, "%.2f")) px, p99 \(n(t.displacementP99Px, "%.2f")) px (search radius \(n(t.maxDisplacementSettingPx, "%.0f")) px)"))
        </table>
        """)
        sections.append("""
        <h2>Time-averaged velocity field</h2><table>
        \(row("Grid", "\(f.columns) × \(f.rows) cells of \(n(f.cellSizePx, "%.0f")) px" + (f.cellSizeUm.map { String(format: " (%.3g µm)", $0) } ?? "")))
        \(row("Coverage", "\(f.validCells) valid of \(f.columns * f.rows) cells (\(n(f.coveragePercent, "%.0f")) %), median \(n(f.samplesPerValidCellMedian, "%.0f")) samples per cell"))
        \(row("Mean velocity (area average)", "u = \(n(f.meanU)) , v = \(n(f.meanV)) \(f.speedUnit)"))
        \(row("Speed of mean field", "mean \(n(f.meanSpeedOfMeanField)), max \(n(f.maxSpeedOfMeanField)) \(f.speedUnit)"))
        \(row("Sample speeds", "median \(n(f.sampleSpeedMedian)), p95 \(n(f.sampleSpeedP95)) \(f.speedUnit)"))
        \(row("Fluctuation RMS (median cell)", "\(n(f.fluctuationRMSMedian)) \(f.speedUnit)"))
        \(row("Turbulence intensity (median cell)", n(f.turbulenceIntensityMedian, "%.2f")))
        \(row("Statistical uncertainty of mean", "median \(n(f.relativeUncertaintyMedian.map { $0 * 100 }, "%.1f")) % of local speed; \(f.cellsBelow10PercentUncertainty) cells below 10 %"))
        \(row("Vorticity", "max |ω| \(n(f.vorticityMaxAbs)) 1/s, mean |ω| \(n(f.vorticityMeanAbs)) 1/s"))
        \(row("Divergence", "mean |div| \(n(f.divergenceMeanAbs)) 1/s"))
        </table>
        """)
        if let q = e.piv {
            sections.append("""
            <h2>PIV</h2><table>
            \(row("Interrogation windows", q.passes.map(String.init).joined(separator: " → ") + " px (final \(q.finalWindowPx) px full-frame, spacing \(n(q.vectorSpacingPx, "%.0f")) px)"))
            \(row("Vectors", "valid \(n(q.validPercent, "%.1f")) %, replaced \(n(q.replacedPercent, "%.1f")) %, invalid \(n(q.invalidPercent, "%.1f")) %; median correlation \(n(q.correlationMedian, "%.2f"))"))
            \(row("Fields computed", "\(q.fieldsComputed)"))
            \(q.ensemble.map { en in row("Ensemble correlation", "\(en.pairs) pairs (\(en.pairSpacingFrames) frames apart, \(en.windowPx) px windows): valid \(n(en.validPercent, "%.1f")) %, replaced \(n(en.replacedPercent, "%.1f")) %; median peak ratio \(n(en.medianPeakRatio, "%.2f")), median peak \(n(en.medianPeakCorrelation, "%.2f"))" + (en.differenceFromVectorAverage.map { String(format: "; differs from the vector average by %.1f %% of the typical speed (median)", $0 * 100) } ?? "")) } ?? "")
            \(row("Camera-shake compensation", q.shakeCompensation ? "on: \(q.shakePairsCorrected) pairs corrected, \(q.shakePairsLearning) learning; shake median \(n(q.shakeMedianPx, "%.2f")) px, p95 \(n(q.shakeP95Px, "%.2f")) px per pair" + (e.cameraMotion.map { " — " + $0.text } ?? "") : "off"))
            \(row("Masked windows", n(q.maskedPercent, "%.1f %%")))
            \(row("Random uncertainty of one vector", "median \(n(q.uncertaintyMedianPx, "%.3f")) px, p95 \(n(q.uncertaintyP95Px, "%.3f")) px per pair (correlation statistics)"))
            \(row("Particle-image diameter", n(q.particleImageDiameterPx, "%.1f px") + (q.peakLockingIndex.map { String(format: "; peak-locking index %.2f", $0) } ?? "")))
            </table>
            """)
        }
        if let c = e.corrections {
            sections.append("""
            <h2>Scene corrections</h2><table>
            \(row("Background", c.background))
            \(row("Masks", "glare \(c.glareMasking ? "on" : "off"), glints \(c.saturationMasking ? "on" : "off"), \(c.exclusions) exclusion region(s); masked share of the image: median \(n(c.maskedPercentMedian, "%.1f")) % (glare \(n(c.glarePercentMedian, "%.1f")) %, glints \(n(c.saturatedPercentMedian, "%.2f")) %)"))
            \(row("Container", c.container))
            \(row("Refraction", c.refractionCorrected ? "corrected" + (c.rectifiedGrid ? "; figures and mean_field.csv on a regular grid in true plane coordinates" : "") : "not corrected"))
            \(row("Length scale", c.lengthScaleSource))
            </table>
            """)
        }
        if let methods {
            sections.append("<h2>Methods (generated)</h2><p style=\"font-size:14px;line-height:1.5\">\(esc(methods))</p>")
        }
        if let df = e.diffusion {
            let est = df.estimate
            sections.append("""
            <h2>Brownian motion</h2><table>
            \(row("Diffusion coefficient", "\(n(est.d)) ± \(n(est.standardError)) px²/s" + (df.dUm2PerS.map { String(format: " = %.3g ± %.2g µm²/s", $0, df.standardErrorUm2PerS ?? 0) } ?? "")))
            \(row("Per axis", "Dx \(n(est.dx)), Dy \(n(est.dy)) px²/s"))
            \(row("Localisation noise σ", n(est.localizationNoisePx, "%.3f px") + (df.localizationNoiseUm.map { String(format: " (%.3g µm)", $0) } ?? "")))
            \(row("One-frame Brownian step", n(est.brownianStepPx, "%.3f px")))
            \(row("Displacement pairs", "lag 1: \(est.pairsLag1), lag 2: \(est.pairsLag2), rejected as mismatches: \(est.rejectedSteps)"))
            \(row("Stokes–Einstein diameter", df.stokesEinsteinDiameterNm.map { String(format: "%.0f nm (T = %.1f °C, η = %.3f mPa·s)", $0, df.temperatureC, df.viscosityMPaS) } ?? "–"))
            \(row("Interpretation", df.interpretation))
            </table>
            """)
        }
        let warn = e.warnings.isEmpty ? "<p>No warnings.</p>" : "<ul>" + e.warnings.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        let figs = images.map { "<figure><img src=\"data:image/png;base64,\($0.png.base64EncodedString())\" alt=\"\(esc($0.title))\"><figcaption>\(esc($0.title)) (\($0.file))</figcaption></figure>" }.joined()
        let date = ISO8601DateFormatter().string(from: e.generatedAt)
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>LivePTV evaluation</title><style>
        body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:980px;margin:24px auto;padding:0 16px;color:#1b1b1f;background:#fff}
        h1{font-size:22px;margin-bottom:4px}h2{font-size:17px;margin-top:28px;border-bottom:1px solid #ddd;padding-bottom:4px}
        table{border-collapse:collapse;width:100%;font-size:14px}th{text-align:left;width:34%;color:#555;font-weight:500;padding:4px 8px 4px 0;vertical-align:top}
        td{padding:4px 0}.verdict{font-size:18px;font-weight:600;margin:12px 0}li{margin:4px 0}
        figure{margin:16px 0}img{max-width:100%;border:1px solid #ddd}figcaption{font-size:13px;color:#555}
        @media (prefers-color-scheme: dark){body{background:#151517;color:#e8e8ea}th,figcaption{color:#aaa}h2{border-color:#333}img{border-color:#333}}
        </style></head><body>
        <h1>LivePTV evaluation — \(esc(label))</h1><div>\(date) · calibration: \(e.mmPerPixel.map { String(format: "%.4g mm/px", $0) } ?? "none (pixels)")</div>
        <div class="verdict">Verdict: \(esc(e.verdict))</div>
        <h2>Warnings</h2>\(warn)
        \(sections.joined(separator: "\n"))
        <h2>Figures</h2>\(figs)
        <p style="font-size:13px;color:#777">Velocities: px/s in image coordinates (x right, y down). Vorticity: positive = counter-clockwise on screen. Numbers in evaluation.json; per-cell values in mean_field.csv.</p>
        </body></html>
        """
    }
}
