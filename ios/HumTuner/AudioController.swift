import AVFoundation
import UIKit

/// The microphone and the reference tone.
///
/// The microphone is converted to 16 kHz mono Float32 and handed to the page as base64 chunks; the page
/// runs the same pitch detector as on the web. Owning the audio session here (instead of letting the web
/// view record) is what lets the Taptic Engine keep working while recording.
final class AudioController {
    enum Event {
        case started(sampleRate: Double)
        /// One of the reasons the page has messages for: "denied", "nomic", "busy", "other".
        case failed(reason: String)
        /// Stopped by a call, Siri or the app leaving the screen; restarts on its own when it can.
        case paused
    }

    static let sampleRate: Double = 16_000

    var onEvent: ((Event) -> Void)?
    var onSamples: ((String) -> Void)?

    /// The person pressed Start and hasn't pressed Stop, even if a call has paused the microphone.
    private(set) var wantsToListen = false
    private(set) var isRunning = false

    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioController.sampleRate,
                                          channels: 1, interleaved: false)!
    private var tone: (engine: AVAudioEngine, player: AVAudioPlayerNode, serial: Int)?
    private var toneSerial = 0
    private var observers: [NSObjectProtocol] = []

    private enum MicError: Error { case noInput, format }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.interrupted(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            // The input route or format changed (headphones, Bluetooth): the engine has stopped itself.
            guard let self, (note.object as AnyObject?) === self.engine, self.isRunning else { return }
            self.run()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.tapInstalled = false
            self.isRunning = false
            self.tone = nil
            self.engine = AVAudioEngine()
            if self.wantsToListen { self.run() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Microphone

    func start() {
        wantsToListen = true
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            run()
        case .denied:
            wantsToListen = false
            onEvent?(.failed(reason: "denied"))
        default:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { self.run() } else {
                        self.wantsToListen = false
                        self.onEvent?(.failed(reason: "denied"))
                    }
                }
            }
        }
    }

    func stop() {
        wantsToListen = false
        stopEngine()
        if tone == nil { deactivateSession() }
    }

    /// The app left the screen; we have no background audio, so let go of the microphone until it's back.
    func pause() {
        guard isRunning else { return }
        stopEngine()
        onEvent?(.paused)
    }

    /// Back on screen, or a call ended: pick up where we left off.
    func resumeIfWanted() {
        if wantsToListen && !isRunning { run() }
    }

    private func run() {
        guard wantsToListen else { return }
        stopEngine()
        stopTone()
        do {
            let session = AVAudioSession.sharedInstance()
            // Measurement mode turns off the voice processing (gain control, noise reduction) that would color the pitch.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            // iOS mutes haptics while an app records unless it opts in.
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            guard session.isInputAvailable else { throw MicError.noInput }

            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw MicError.noInput }
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw MicError.format }
            converter.downmix = true
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
                self?.forward(buffer, through: converter)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRunning = true
            onEvent?(.started(sampleRate: Self.sampleRate))
        } catch {
            stopEngine()
            wantsToListen = false
            onEvent?(.failed(reason: Self.reason(for: error)))
        }
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isRunning = false
    }

    /// Runs on the tap's thread.
    private func forward(_ buffer: AVAudioPCMBuffer, through converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow // keep the resampler's state for the next buffer
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
        let base64 = Data(bytes: samples, count: Int(out.frameLength) * MemoryLayout<Float>.size).base64EncodedString()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.onSamples?(base64)
        }
    }

    private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if isRunning {
                stopEngine()
                onEvent?(.paused)
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume) && UIApplication.shared.applicationState == .active { resumeIfWanted() }
        @unknown default:
            break
        }
    }

    private static func reason(for error: Error) -> String {
        if case MicError.noInput = error { return "nomic" }
        switch AVAudioSession.ErrorCode(rawValue: (error as NSError).code) {
        case .isBusy?, .insufficientPriority?, .cannotStartRecording?, .cannotInterruptOthers?, .siriIsRecording?:
            return "busy"
        default:
            return "other"
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Reference tone

    func playTone(hz: Double, duration: Double) {
        stopTone()
        let hz = min(1000, max(40, hz)), duration = min(5, max(0.3, duration))
        do {
            if !isRunning {
                // Not listening: play like a music app, so the silent switch doesn't mute it.
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
            }
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            engine.attach(player)
            var rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if rate <= 0 { rate = 48_000 }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buffer = Self.toneBuffer(hz: hz, duration: duration, format: format) else { return }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            toneSerial += 1
            let serial = toneSerial
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.toneEnded(serial) }
            }
            player.play()
            tone = (engine, player, serial)
        } catch {
            stopTone()
        }
    }

    private func toneEnded(_ serial: Int) {
        guard let tone, tone.serial == serial else { return }
        stopTone()
        if !wantsToListen { deactivateSession() }
    }

    private func stopTone() {
        guard let tone else { return }
        self.tone = nil
        tone.player.stop()
        tone.engine.stop()
    }

    /// Same recipe as the web page: rich harmonics so a phone speaker still carries a low pitch.
    private static func toneBuffer(hz: Double, duration: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(duration * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let amps: [Double] = [1, 0.7, 0.5, 0.35, 0.22, 0.14, 0.09]
        var peak = 0.0
        var wave = [Double](repeating: 0, count: Int(frames))
        for i in 0..<Int(frames) {
            let phase = 2 * Double.pi * hz * Double(i) / rate
            var s = 0.0
            for (k, a) in amps.enumerated() { s += a * sin(Double(k + 1) * phase) }
            wave[i] = s
            peak = max(peak, abs(s))
        }
        let gain = peak > 0 ? 0.35 / peak : 0
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let envelope = min(1, t / 0.06, (duration - t) / 0.2)
            out[i] = Float(wave[i] * gain * max(0, envelope))
        }
        return buffer
    }
}
