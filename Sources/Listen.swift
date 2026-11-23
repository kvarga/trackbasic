// Listening test: plays a PLAY string on the trackpad while recording the Mac's microphone, then
// scores every note: how far above the room it is, how much of the sound is the note itself, and
// whether the strongest pitch heard is the one that was played.
//
//   TrackBASIC --listen "T150 O4 L4 EEFG" [--style seg=0.02,partials=1:1;2:0.3,sustain=0.6,decay=0.08]
//              [--wav out.wav] [--quiet]

import AVFoundation
import Foundation

final class MicRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private(set) var samples: [Float] = []
    private var host0: UInt64 = 0
    private(set) var sampleRate = 48000.0

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, when in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            self.lock.lock()
            if self.samples.isEmpty && when.isHostTimeValid { self.host0 = when.hostTime }
            self.samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
            self.lock.unlock()
        }
        try engine.start()
    }

    func stop() { engine.inputNode.removeTap(onBus: 0); engine.stop() }

    /// The sample index recorded at a mach_absolute_time moment.
    func index(at t: UInt64) -> Int {
        lock.lock(); defer { lock.unlock() }
        return Int((Double(Int64(t) - Int64(host0)) / ticksPerSecond * sampleRate).rounded())
    }

    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
}

/// Amplitude of the sinusoid at `f` in `x`, by a Hann-windowed Goertzel filter.
func toneAmplitude(_ x: ArraySlice<Float>, _ f: Double, _ sr: Double) -> Double {
    let n = x.count
    guard n > 16 else { return 0 }
    let w = 2 * Double.pi * f / sr
    let coeff = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0, wsum = 0.0
    var i = 0
    for v in x {
        let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
        wsum += win
        let s0 = Double(v) * win + coeff * s1 - s2
        s2 = s1; s1 = s0
        i += 1
    }
    let re = s1 - s2 * cos(w), im = s2 * sin(w)
    return 2 * sqrt(re * re + im * im) / wsum
}

func meanSquare(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return 0 }
    let mean = x.reduce(0.0) { $0 + Double($1) } / Double(x.count)
    return x.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(x.count)
}

func parseStyle(_ s: String) -> HapticStyle {
    var st = HapticStyle()
    for part in s.split(separator: ",") {
        let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "seg": st.segment = Double(kv[1]) ?? st.segment
        case "level": st.level = Double(kv[1]) ?? st.level
        case "periods": st.periods = Int(kv[1]) ?? 0
        case "sustain": st.sustain = Double(kv[1]) ?? st.sustain
        case "decay": st.decay = Double(kv[1]) ?? st.decay
        case "partials":
            st.partials = kv[1].split(separator: ";").compactMap { p in
                let a = p.split(separator: ":").compactMap { Double($0) }
                return a.count == 2 ? (a[0], a[1]) : nil
            }
        default: break
        }
    }
    return st
}

func runListen(_ args: [String]) -> Int32 {
    guard let i = args.firstIndex(of: "--listen"), i + 1 < args.count else { return 64 }
    let tune = args[i + 1]
    if let s = args.firstIndex(of: "--style"), s + 1 < args.count { Speaker.shared.style = parseStyle(args[s + 1]) }
    let quiet = args.contains("--quiet")

    guard Speaker.shared.motor.available else { print("No haptic motor: \(Speaker.shared.motor.problem ?? "")"); return 1 }
    let notes: [Note]
    do { notes = try MusicState().parse(tune) } catch { print("Bad PLAY string: \(error)"); return 1 }

    // Microphone permission.
    let sem = DispatchSemaphore(value: 0)
    var allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    if !allowed {
        AVCaptureDevice.requestAccess(for: .audio) { ok in allowed = ok; sem.signal() }
        sem.wait()
    }
    guard allowed else { print("Microphone access was denied."); return 1 }

    let mic = MicRecorder()
    do { try mic.start() } catch { print("Couldn't start the microphone: \(error)"); return 1 }
    usleep(900_000)   // room noise
    let noiseEnd = mach_absolute_time()

    var spans: [(hz: Double, start: UInt64, end: UInt64, gapEnd: UInt64)] = []
    for n in notes {
        let s = mach_absolute_time()
        Speaker.shared.tone(hz: n.hz, seconds: n.sound, stop: { false })
        let e = mach_absolute_time()
        Speaker.shared.tone(hz: 0, seconds: n.gap, stop: { false })
        spans.append((n.hz, s, e, mach_absolute_time()))
    }
    usleep(500_000)
    mic.stop()

    let x = mic.snapshot()
    let sr = mic.sampleRate
    let noise = x[max(0, mic.index(at: noiseEnd) - Int(0.7 * sr))..<max(0, mic.index(at: noiseEnd) - Int(0.1 * sr))]
    let noiseMS = max(meanSquare(noise), 1e-14)

    if args.contains("--env") {
        // Level every 10 ms, with the moments each note was started and stopped.
        let hop = Int(0.01 * sr)
        let marks = spans.flatMap { [(mic.index(at: $0.start), "ON"), (mic.index(at: $0.end), "off")] }
        var k = max(0, mic.index(at: noiseEnd) - 5 * hop)
        while k + hop <= x.count {
            let db = 10 * log10(max(meanSquare(x[k..<(k + hop)]), 1e-14) / noiseMS)
            let m = marks.filter { $0.0 >= k && $0.0 < k + hop }.map(\.1).joined(separator: " ")
            print(String(format: "  %6.0fms %6.1f dB %@ %@", Double(k - mic.index(at: noiseEnd)) / sr * 1000, db,
                         String(repeating: "#", count: max(0, Int(db))) as NSString, m as NSString))
            k += hop
        }
    }
    if args.contains("--peaks") { print("  room peaks: " + describePeaks(spectrum(noise, sr), ref: 0)) }

    // Motor-to-microphone latency: the lag (0–100 ms) at which the recording is loudest inside the notes
    // and quietest in the rests between them.
    let hop = max(1, Int(0.002 * sr))
    var env: [Double] = []
    var e0 = 0
    while e0 + hop <= x.count { env.append(meanSquare(x[e0..<(e0 + hop)])); e0 += hop }
    func envMean(_ a: Int, _ b: Int) -> Double {
        let i0 = max(0, a / hop), i1 = min(env.count, b / hop)
        return i1 > i0 ? env[i0..<i1].reduce(0, +) / Double(i1 - i0) : 0
    }
    var latency = 0.0, bestScore = -Double.infinity
    for lagMs in stride(from: 0.0, through: 100, by: 2) {
        let lag = Int(lagMs / 1000 * sr)
        var on = 0.0, off = 0.0
        for sp in spans where sp.hz > 0 {
            let a = mic.index(at: sp.start) + lag, b = mic.index(at: sp.end) + lag, g = mic.index(at: sp.gapEnd) + lag
            on += log10(envMean(a, b) + 1e-14)
            if g - b > hop * 4 { off += log10(envMean(b, g) + 1e-14) }
        }
        if on - off > bestScore { bestScore = on - off; latency = lagMs / 1000 }
    }
    var rows: [(hz: Double, loud: Double, snr: Double, purity: Double, peakCents: Double, gap: Double)] = []
    for sp in spans where sp.hz > 0 {
        let a = mic.index(at: sp.start), b = mic.index(at: sp.end), g = mic.index(at: sp.gapEnd)
        let lat = Int(latency * sr)
        let len = b - a
        let n0 = a + lat + Int(Double(len) * 0.1), n1 = b + lat - Int(Double(len) * 0.1)
        guard n0 >= 0, n1 <= x.count, n1 > n0 + 256 else { continue }
        let seg = x[n0..<n1]
        let ms = meanSquare(seg)
        let af = toneAmplitude(seg, sp.hz, sr)
        // Noise at the same frequency, over a window of the same length.
        let nWin = noise.prefix(seg.count)
        let anf = max(toneAmplitude(nWin, sp.hz, sr), 1e-9)
        // Strongest pitch between a half and four times the note, in 10-cent steps.
        var best = (amp: 0.0, f: sp.hz)
        var f = sp.hz * 0.5
        while f < min(sp.hz * 4.2, sr / 2 - 100) {
            let v = toneAmplitude(seg, f, sr)
            if v > best.amp { best = (v, f) }
            f *= pow(2, 10.0 / 1200)
        }
        let spec = spectrum(seg, sr)
        let specPower = spec.reduce(0.0) { $0 + $1.a * $1.a }
        var harmPower = 0.0
        for k in 1...8 where Double(k) * sp.hz < 8000 {
            let h = toneAmplitude(seg, Double(k) * sp.hz, sr); harmPower += h * h
        }
        // Each harmonic is measured once against a quarter-tone grid: scale to compare like with like.
        let harmonicity = min(1, harmPower / max(specPower, 1e-20) * 2)
        if args.contains("--peaks") {
            print("  \(noteName(sp.hz)) \(Int(sp.hz))Hz peaks: " + describePeaks(spec, ref: sp.hz))
        }
        // Silence between notes: how far the level drops in the gap.
        var gapDB = 0.0
        if g - b > Int(0.02 * sr), b + lat + Int(0.01 * sr) < g + lat, g + lat <= x.count {
            let gs = x[(b + lat + Int(0.01 * sr))..<(g + lat)]
            gapDB = 10 * log10(max(meanSquare(gs), 1e-14) / max(ms, 1e-14))
        }
        rows.append((sp.hz, 10 * log10(ms / noiseMS), 20 * log10(af / anf), harmonicity,
                     1200 * log2(best.f / sp.hz), gapDB))
    }

    if !quiet {
        print("  note     Hz   loud dB  note dB  harm%   heard(cents)  gap dB")
        for r in rows {
            print(String(format: "  %-5@ %6.0f  %7.1f  %7.1f  %5.0f%%  %+11.0f  %6.1f", noteName(r.hz) as NSString, r.hz, r.loud, r.snr, r.purity * 100, r.peakCents, r.gap))
        }
    }
    // Absolute levels (dB re full scale at the microphone), steadier than levels over a changing room.
    let dbfs = rows.map { $0.loud + 10 * log10(noiseMS) }
    let mean = dbfs.reduce(0, +) / Double(max(1, dbfs.count))
    let sd = sqrt(dbfs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, dbfs.count)))
    // Flutter: how much the level swings inside a note (90th minus 10th percentile of 5 ms frames).
    var flutters: [Double] = []
    let lagN = Int(latency * sr), fh = Int(0.005 * sr)
    for sp in spans where sp.hz > 0 {
        let a = mic.index(at: sp.start) + lagN, b = mic.index(at: sp.end) + lagN
        let len = b - a
        var k = a + len / 10
        var fr: [Double] = []
        while k + fh <= b - len / 10 && k + fh <= x.count { fr.append(10 * log10(max(meanSquare(x[k..<(k + fh)]), 1e-14))); k += fh }
        if fr.count >= 6 { fr.sort(); flutters.append(fr[fr.count * 9 / 10] - fr[fr.count / 10]) }
    }
    print(String(format: "FLUTTER mean %.1f dB", flutters.reduce(0, +) / Double(max(1, flutters.count))))
    print(String(format: "LEVEL mean %.1f dBFS, weakest %.1f dBFS, note-to-note spread (sd) %.1f dB", mean, dbfs.min() ?? 0, sd))
    let snrs = rows.map(\.snr).sorted(), louds = rows.map(\.loud).sorted()
    let onPitch = rows.filter { abs($0.peakCents) < 50 }.count
    let gaps = rows.map(\.gap).filter { $0 != 0 }
    let written = notes.reduce(0.0) { $0 + $1.sound + $1.gap }
    let played = Double((spans.last?.gapEnd ?? 0) - (spans.first?.start ?? 0)) / ticksPerSecond
    let steady = rows.map { $0.loud }
    print(String(format: "TIMING played %.2f s for %.2f s written (%+.0f%%), motor-to-mic latency %.0f ms", played, written, (played / written - 1) * 100, latency * 1000))
    _ = steady
    print(String(format: "SUMMARY loud median %.1f min %.1f | note dB median %.1f min %.1f spread %.1f | harmonicity mean %.0f%% | on-pitch %d/%d | gap mean %.1f dB",
                 louds[louds.count / 2], louds.first ?? 0, snrs[snrs.count / 2], snrs.first ?? 0, (snrs.last ?? 0) - (snrs.first ?? 0),
                 rows.map(\.purity).reduce(0, +) / Double(max(1, rows.count)) * 100, onPitch, rows.count,
                 gaps.reduce(0, +) / Double(max(1, gaps.count))))

    if let w = args.firstIndex(of: "--wav"), w + 1 < args.count {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        if let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: args[w + 1]), settings: fmt.settings),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count)) {
            buf.frameLength = AVAudioFrameCount(x.count)
            for (k, v) in x.enumerated() { buf.floatChannelData![0][k] = v }
            try? file.write(from: buf)
        }
    }
    return 0
}

func noteName(_ f: Double) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let midi = Int((69 + 12 * log2(f / 440)).rounded())
    return names[(midi % 12 + 12) % 12] + String(midi / 12 - 1)
}

/// Amplitudes from 60 Hz to 8 kHz in quarter-tone steps.
func spectrum(_ x: ArraySlice<Float>, _ sr: Double) -> [(f: Double, a: Double)] {
    var spec: [(f: Double, a: Double)] = []
    var q = 60.0
    while q < 8000 { spec.append((q, toneAmplitude(x, q, sr))); q *= pow(2, 50.0 / 1200) }
    return spec
}

func describePeaks(_ spec: [(f: Double, a: Double)], ref: Double) -> String {
    var peaks: [(f: Double, a: Double)] = []
    for k in 1..<(spec.count - 1) where spec[k].a > spec[k - 1].a && spec[k].a >= spec[k + 1].a { peaks.append(spec[k]) }
    peaks.sort { $0.a > $1.a }
    let top = peaks.first?.a ?? 1
    return peaks.prefix(6).map { p in
        (ref > 0 ? String(format: "%5.0fHz(x%.2f)", p.f, p.f / ref) : String(format: "%5.0fHz", p.f)) + String(format: " %+.0fdB", 20 * log10(p.a / top))
    }.joined(separator: "  ")
}
