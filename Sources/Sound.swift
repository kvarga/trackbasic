// Sound output: QBasic's PC speaker, played on the MacBook trackpad's haptic motor.
//
// The motor code is adapted from nospeaker (https://github.com/os6/nospeaker, MIT license,
// by Cody Collier): MultitouchSupport is a private macOS framework, resolved at run time, whose
// MTActuationCreateFromDictionary describes a vibration as sine tones and MTActuationActuate plays
// it on the motor. Driven hundreds or thousands of times a second, the glass makes audible sound.
//
// If there is no Force Touch trackpad (or the user picks it), tones go to the normal speakers as a
// square wave instead, which is what a real PC speaker sounded like.

import AVFoundation
import Darwin
import Foundation

// MARK: - Clock

private var timebase: mach_timebase_info_data_t = {
    var t = mach_timebase_info_data_t()
    mach_timebase_info(&t)
    return t
}()
let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)

/// Waits until a mach_absolute_time moment: sleeps, then spins for the last ~1.5 ms for tight timing.
func waitUntil(_ t: UInt64, stop: () -> Bool) {
    let margin = UInt64(0.0015 * ticksPerSecond)
    while !stop() {
        let n = mach_absolute_time()
        if n >= t { return }
        if t - n > margin { usleep(useconds_t(min(Double(t - n - margin) / ticksPerSecond * 1e6, 20_000))) }
    }
}

// MARK: - The haptic motor (MultitouchSupport)

private let mtHandle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
private func sym<T>(_ name: String, _: T.Type) -> T? {
    guard let mtHandle, let p = dlsym(mtHandle, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

private let createList = sym("MTDeviceCreateList", CreateList.self)
private let getID = sym("MTDeviceGetDeviceID", GetID.self)
private let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
private let actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
private let actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self)
private let actuationCreate = sym("MTActuationCreateFromDictionary", ActuationCreate.self)
private let actuationPlay = sym("MTActuationActuate", ActuationPlay.self)

final class HapticMotor {
    private var motor: CFTypeRef?
    private var motorPointer: UnsafeMutableRawPointer?
    private(set) var problem: String?

    init() {
        guard let createList, let getID, let actuatorCreate, let actuatorOpen, actuationCreate != nil, actuationPlay != nil else {
            problem = "This macOS doesn't have the MultitouchSupport functions needed."
            return
        }
        guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
            problem = "No trackpad found."
            return
        }
        var ids: [(id: UInt64, builtIn: Bool)] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
        }
        for d in ids.sorted(by: { $0.builtIn && !$1.builtIn }) {
            if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
                motor = ref
                motorPointer = UnsafeMutableRawPointer(mutating: Unmanaged.passUnretained(ref as AnyObject).toOpaque())
                return
            }
        }
        problem = "The trackpad has no Force Touch haptic motor."
    }

    var available: Bool { motorPointer != nil }

    /// Plays sine tones together for `ms` at `level` (0…1). Never past the motor's normal maximum.
    func play(_ tones: [(hz: Double, amp: Double)], ms: Double, level: Float) {
        guard let motorPointer, !tones.isEmpty else { return }
        let sum = max(tones.reduce(0) { $0 + $1.amp }, 0.0001)
        let shape: [String: Any] = [
            "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
            "Tones": tones.map { ["Type": "Sine", "Amplitude": $0.amp / sum, "DurationMS": ms, "DelayMS": 0.0, "FrequencykHz": $0.hz / 1000] },
        ]
        guard let act = actuationCreate!(shape as CFDictionary, 0) else { return }
        _ = actuationPlay!(act, motorPointer, 0, min(1, max(0, level)), 0)
        Unmanaged<AnyObject>.fromOpaque(act).release()
    }
}

// MARK: - Square-wave fallback through the speakers

final class SquareWave {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private var lock = os_unfair_lock()
    private var freq = 0.0
    private var phase = 0.0
    private var started = false
    private let sampleRate: Double

    init() {
        sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate > 0 ? engine.outputNode.outputFormat(forBus: 0).sampleRate : 44100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl -> OSStatus in
            os_unfair_lock_lock(&self.lock)
            let f = self.freq
            os_unfair_lock_unlock(&self.lock)
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let step = f / self.sampleRate
            for frame in 0..<Int(frameCount) {
                var v: Float = 0
                if f > 0 {
                    v = self.phase < 0.5 ? 0.12 : -0.12
                    self.phase += step
                    if self.phase >= 1 { self.phase -= 1 }
                }
                for b in buffers { b.mData!.assumingMemoryBound(to: Float.self)[frame] = v }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func set(_ hz: Double) {
        if !started { started = (try? engine.start()) != nil }
        os_unfair_lock_lock(&lock); freq = hz; os_unfair_lock_unlock(&lock)
    }
}

// MARK: - The speaker QBasic programs talk to

enum SoundOutput: String, CaseIterable {
    case trackpad = "Trackpad"
    case speakers = "Speakers"
    case off = "Off"
}

final class Speaker {
    static let shared = Speaker()

    let motor = HapticMotor()
    private lazy var square = SquareWave()
    var output: SoundOutput

    private init() {
        output = .trackpad
        if !motor.available { output = .speakers }
    }

    /// Plays one note for `seconds`, blocking the caller (QBasic's foreground music). `hz` of 0 is a rest.
    /// The motor is played in whole periods of the wave (about 20 ms at a time), as nospeaker does, so
    /// segments join without clicks.
    func tone(hz: Double, seconds: Double, stop: () -> Bool) {
        guard seconds > 0 else { return }
        let start = mach_absolute_time()
        let end = start + UInt64(seconds * ticksPerSecond)
        let audible = hz >= 37 && hz <= 32767
        switch output {
        case .trackpad where audible && motor.available:
            var t = 0.0
            while t < seconds && !stop() {
                let seg = max(1, (0.02 * hz).rounded()) / hz
                let len = min(seg, seconds - t + 0.002)
                motor.play([(hz, 1)], ms: len * 1000, level: 1)
                t += seg
                waitUntil(start + UInt64(min(t, seconds) * ticksPerSecond), stop: stop)
            }
        case .speakers where audible:
            square.set(hz)
            waitUntil(end, stop: stop)
            square.set(0)
        default:
            waitUntil(end, stop: stop)
        }
    }
}
