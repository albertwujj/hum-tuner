import SwiftUI

@main
struct HumTunerApp: App {
    var body: some Scene {
        WindowGroup {
            TunerView().ignoresSafeArea()
        }
    }
}

/// The tuner itself is the web page (the same one as albertwujj.github.io/hum-tuner); the app adds
/// what Safari can't: haptic taps near the target, which needs the app to own the microphone.
struct TunerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TunerViewController { TunerViewController() }
    func updateUIViewController(_ controller: TunerViewController, context: Context) {}
}
