import AVFoundation
import CoreHaptics
import UIKit

/// Short Taptic Engine taps whose strength and crispness the page chooses.
final class Haptics {
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private lazy var fallback = UIImpactFeedbackGenerator(style: .rigid)

    /// Starts the engine ahead of the first tap so it isn't late.
    func prepare() {
        if supported { _ = try? readyEngine() } else { fallback.prepare() }
    }

    func tap(intensity: Float, sharpness: Float) {
        let intensity = min(1, max(0, intensity)), sharpness = min(1, max(0, sharpness))
        guard supported else {
            fallback.impactOccurred(intensity: CGFloat(intensity))
            return
        }
        do {
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0)
            let player = try readyEngine().makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            engine = nil // rebuilt on the next tap
            fallback.impactOccurred(intensity: CGFloat(intensity))
        }
    }

    private func readyEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        // Tied to the app's audio session, whose allowHapticsAndSystemSoundsDuringRecording keeps taps
        // coming while the microphone is on.
        let engine = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
        engine.playsHapticsOnly = true
        // Stopped (audio session change, app in background) or reset by the system: rebuild on the next tap.
        let drop: () -> Void = { [weak self, weak engine] in
            DispatchQueue.main.async {
                if let self, let engine, self.engine === engine { self.engine = nil }
            }
        }
        engine.resetHandler = drop
        engine.stoppedHandler = { _ in drop() }
        try engine.start()
        self.engine = engine
        return engine
    }
}
