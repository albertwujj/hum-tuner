# Nasal Hum Tuner

A live pitch reader for nasal humming practice. Hum through your nose and the app shows your pitch in hertz, how far you are from the target (130 Hz by default), and lights up more strongly the closer you get. Each hum is scored, and daily totals are kept in your browser.

Open it at https://albertwujj.github.io/hum-tuner/ on a Mac or iPhone. On iPhone, use Safari's Share › Add to Home Screen to run it like an app.

- Pitch detection: YIN, about 60 times a second, on the device. Audio is never recorded or uploaded.
- Brief misreadings (a jump to 60 Hz on a breath, a subharmonic) are held back from the trace, readout and scores unless they last long enough to be a real pitch change.
- Near the target (±50 cents) the page ticks, faster and louder the closer you get; on Android it also vibrates. A switch under the mic meter turns this off.
- Single file (`index.html`), no build step, no dependencies besides Google Fonts.
- The microphone needs HTTPS (or localhost). To run locally: `python3 -m http.server` in this folder, then open http://localhost:8000.
- Tests: `node test/pitch.test.mjs` (detector accuracy, outlier rejection, the iPhone app's audio path).

## iPhone app (vibration)

Safari can't vibrate an iPhone, so `ios/` holds a small app that shows the same page and taps the phone's Taptic Engine near the target. The app owns the microphone (iOS mutes haptics while a web view records) and streams 16 kHz audio to the page, which runs the same detector. It loads the live site, so page updates arrive without reinstalling, and falls back to a copy bundled at build time when offline.

To install on your own iPhone (needs an Apple developer team; set `DEVELOPMENT_TEAM` in the project to yours):

1. Connect the iPhone by cable, unlock it and tap Trust. Turn on Settings › Privacy & Security › Developer Mode if asked.
2. Build: `xcodebuild -project ios/HumTuner.xcodeproj -scheme HumTuner -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build`
3. Install: `xcrun devicectl device install app --device <device id from 'xcrun devicectl list devices'> build/Build/Products/Release-iphoneos/HumTuner.app`

Or open `ios/HumTuner.xcodeproj` in Xcode and press Run.
