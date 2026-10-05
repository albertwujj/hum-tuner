# Nasal Hum Tuner

A live pitch reader for nasal humming practice. Hum through your nose and the app shows your pitch in hertz, how far you are from the target (130 Hz by default), and lights up more strongly the closer you get. Each hum is scored, and daily totals are kept in your browser.

Open it at https://albertwujj.github.io/hum-tuner/ on a Mac or iPhone. On iPhone, use Safari's Share › Add to Home Screen to run it like an app.

- Pitch detection: YIN, about 60 times a second, on the device. Audio is never recorded or uploaded.
- Single file (`index.html`), no build step, no dependencies besides Google Fonts.
- The microphone needs HTTPS (or localhost). To run locally: `python3 -m http.server` in this folder, then open http://localhost:8000.
