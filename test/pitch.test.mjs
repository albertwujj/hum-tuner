// Detector and tracker tests. Run with: node test/pitch.test.mjs
// Pulls the code between the DETECTOR START/END markers out of index.html, so it tests what ships.
import fs from 'node:fs';

const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const m = html.match(/\/\* DETECTOR START \*\/([\s\S]*?)\/\* DETECTOR END \*\//);
const api = new Function(m[1] + '; return { createYin, createTracker, createPcmAnalyzer, closeness, centsBetween, median, PITCH, TRACK };')();
const { createYin, createTracker, createPcmAnalyzer, centsBetween, TRACK } = api;

let seed = 12345;
const rand = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
const gauss = () => { let u = 0; while (!u) u = rand(); const v = rand(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };

let fails = 0, total = 0;
function check(cond, msg) { total++; if (!cond) { fails++; console.log('FAIL', msg); } }

function synth(sr, n, f, amps, noise, opts = {}) {
  const x = new Float32Array(n);
  const phases = amps.map(() => rand() * 2 * Math.PI);
  let ph = 0;
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    const fi = opts.vibrato ? f * (1 + opts.vibrato * Math.sin(2 * Math.PI * 5.5 * t)) : f;
    ph += 2 * Math.PI * fi / sr;
    let s = 0;
    for (let k = 0; k < amps.length; k++) s += amps[k] * Math.sin((k + 1) * ph + phases[k]);
    x[i] = 0.05 * s + noise * gauss();
  }
  return x;
}

const HUM = [1, 0.55, 0.3, 0.2, 0.12, 0.08];
const WEAK = [0.2, 1, 0.6, 0.3, 0.15];

/* ---------- Detector accuracy across pitch and analysis rates ---------- */
{
  const freqs = []; for (let f = 62; f < 900; f *= 1.03) freqs.push(+f.toFixed(2)); freqs.push(128, 130, 131.5);
  const rates = [16000, 17640, 22050, 24000, 32000]; // 48k/3, 88.2k/5, 44.1k/2, 24k/1, 32k/1
  const worst = { pure: 0, hum: 0, weak: 0, vib: 0 };
  for (const sr of rates) {
    const yin = createYin(sr);
    for (const f of freqs) {
      const cases = {
        pure: synth(sr, yin.N + 50, f, [1], 0),
        hum: synth(sr, yin.N + 50, f, HUM, 0.0016),
        weak: synth(sr, yin.N + 50, f, WEAK, 0.0016),
      };
      for (const [name, x] of Object.entries(cases)) {
        const r = yin.detect(x);
        const err = Math.abs(centsBetween(r.hz, f));
        worst[name] = Math.max(worst[name], err);
        check(err < (name === 'pure' ? 1 : 3), `${name} sr=${sr} f=${f}: got ${r.hz.toFixed(3)} (${err.toFixed(2)}c)`);
        check(r.clarity >= TRACK.CLARITY, `${name} sr=${sr} f=${f}: clarity ${r.clarity.toFixed(3)}`);
      }
    }
    for (let k = 0; k < 40; k++) {
      const r = yin.detect(synth(sr, yin.N + 50, 130, HUM, 0.0016, { vibrato: 0.003 }));
      const err = Math.abs(centsBetween(r.hz, 130));
      worst.vib = Math.max(worst.vib, err);
      check(err < 12, `vibrato sr=${sr}: ${r.hz.toFixed(2)}`);
    }
  }
  console.log('worst cents error:', Object.fromEntries(Object.entries(worst).map(([k, v]) => [k, +v.toFixed(3)])));
}

/* ---------- Detector: noise and sub-range input never read as a pitch at the floor ---------- */
{
  const yin = createYin(16000);
  let maxClarity = 0;
  for (let k = 0; k < 300; k++) {
    const x = new Float32Array(yin.N + 10);
    for (let i = 0; i < x.length; i++) x[i] = 0.02 * gauss();
    maxClarity = Math.max(maxClarity, yin.detect(x).clarity);
  }
  console.log('white noise max clarity:', maxClarity.toFixed(3));
  check(maxClarity < TRACK.CLARITY, 'white noise flagged as voiced');

  // Rumble (heavily low-passed noise, like breath on the mic) and tones just under MIN_HZ.
  const floorHits = (x) => { const r = yin.detect(x); return r.clarity >= TRACK.CLARITY && r.hz < 70; };
  let rumbleHits = 0;
  for (let k = 0; k < 300; k++) {
    const x = new Float32Array(yin.N + 10);
    let y = 0;
    for (let i = 0; i < x.length; i++) { y += (gauss() - y) * 0.01; x[i] = 0.3 * y; }
    if (floorHits(x)) rumbleHits++;
  }
  console.log('rumble frames read as <70 Hz pitch:', rumbleHits, 'of 300');
  check(rumbleHits === 0, `rumble read as a pitch near the floor ${rumbleHits} times`);
  for (const f of [50, 55, 58, 59.5]) {
    check(!floorHits(synth(16000, yin.N + 10, f, [1], 0.0005)), `pure ${f} Hz read as a pitch near the floor`);
    check(!floorHits(synth(16000, yin.N + 10, f, HUM, 0.0005)), `hum-like ${f} Hz read as a pitch near the floor`);
  }
}

/* ---------- Tracker on scripted detector output ---------- */
// parts: [ms, hz] where hz is a number, 0 (silence), or a function of the frame index within the part.
function frames(parts, fps = 60) {
  const out = [];
  let t = 0;
  for (const [ms, hz] of parts) {
    const n = Math.round(ms / 1000 * fps);
    for (let i = 0; i < n; i++, t += 1000 / fps) out.push({ t, hz: typeof hz === 'function' ? hz(i, n) : hz });
  }
  return out;
}
// Same as the app: a retracted hum start takes its trace points with it.
const retractFrom = (trace) => (from) => { while (trace.length && trace[trace.length - 1].t >= from) trace.pop(); };
function runTracker(fr, target = 130, onPush) {
  const segs = [], trace = [];
  const tk = createTracker(() => target, { end: (s) => segs.push(s), frame: (t, hz) => trace.push({ t, hz }), retract: retractFrom(trace) });
  for (const f of fr) {
    const r = f.hz ? { hz: f.hz, clarity: 0.95, rms: 0.02 } : { hz: 0, clarity: 0.2, rms: 0.0004 };
    tk.push(f.t, r, false);
    if (onPush) onPush(f, tk);
  }
  tk.flush();
  return { segs, trace, tk };
}
const jitter = (hz) => () => hz * Math.pow(2, (rand() - 0.5) * 6 / 1200); // ±3 cents
const inBand = (trace, lo, hi) => trace.every((p) => p.hz >= lo && p.hz <= hi);

// Spikes at the start, middle and end of a 3 s hum must not reach the trace, scores or the lock streak.
for (const spike of [60, 65, 72, 260, 400]) {
  for (const len of [1, 2, 4, 6]) {
    const at = new Set();
    const hum = (i, n) => {
      const pos = [0, Math.floor(n * 0.3), Math.floor(n * 0.6), n - len];
      for (const p of pos) if (i >= p && i < p + len) return spike;
      return jitter(130)();
    };
    const { segs, trace } = runTracker(frames([[500, 0], [3000, hum], [600, 0]]));
    const tag = `spike ${spike} Hz x${len}`;
    check(segs.length === 1, `${tag}: expected 1 hum, got ${segs.length}`);
    check(inBand(trace, 128, 132), `${tag}: trace left 128–132 Hz (${trace.filter((p) => p.hz < 128 || p.hz > 132).map((p) => p.hz.toFixed(1)).join(',')})`);
    if (segs.length === 1) {
      const s = segs[0];
      check(s.score >= 99, `${tag}: score ${s.score}`);
      check(Math.abs(s.hz - 130) < 0.5, `${tag}: median ${s.hz}`);
      check(s.dur > 2750 && s.dur < 3050, `${tag}: duration ${Math.round(s.dur)}`);
      check(s.lockMs > 2700, `${tag}: lock streak ${Math.round(s.lockMs)} broken by spikes`);
      check(s.nearMs > 2700, `${tag}: near time ${Math.round(s.nearMs)}`);
    }
  }
}

// Spikes with unvoiced frames around them (the usual real-world shape) and at a lower frame rate.
{
  const pattern = (i) => (i % 40 === 20 ? 0 : i % 40 === 21 ? 61 : i % 40 === 22 ? 0 : jitter(130)());
  for (const fps of [60, 30]) {
    const { segs, trace } = runTracker(frames([[400, 0], [4000, pattern], [500, 0]], fps));
    check(segs.length === 1 && segs[0].score >= 99 && segs[0].lockMs > 3600, `gapped spikes @${fps}fps: ${JSON.stringify(segs.map((s) => [s.score, Math.round(s.lockMs)]))}`);
    check(inBand(trace, 128, 132), `gapped spikes @${fps}fps: trace left band`);
  }
}

// A burst of junk (voiced but inconsistent pitch) must not open a hum.
{
  const junk = () => 60 + rand() * 340;
  const { segs, trace } = runTracker(frames([[300, 0], [1500, junk], [500, 0]]));
  check(segs.length === 0 && trace.length === 0, `junk burst opened ${segs.length} hums, ${trace.length} trace points`);
}

// Junk after a hum must not stretch it.
{
  const junk = () => 60 + rand() * 340;
  const { segs } = runTracker(frames([[300, 0], [2000, jitter(130)], [1000, junk], [500, 0]]));
  check(segs.length === 1 && Math.abs(segs[0].dur - 2000) < 120, `junk after hum: ${JSON.stringify(segs.map((s) => Math.round(s.dur)))}`);
}

// A real, sustained pitch change is accepted within ~200 ms, with its true start time.
{
  let switchedAt = -1;
  const jumpT = 300 + 1500;
  const { segs, trace } = runTracker(frames([[300, 0], [1500, jitter(130)], [1500, jitter(165)], [400, 0]]), 130, (f, tk) => {
    if (switchedAt < 0 && tk.s.humming && tk.s.hz > 160) switchedAt = f.t;
  });
  check(segs.length === 1, `jump: expected one continuous hum, got ${segs.length}`);
  check(switchedAt >= jumpT && switchedAt - jumpT <= 200, `jump: readout switched ${Math.round(switchedAt - jumpT)} ms after the change`);
  const first = trace.find((p) => p.hz > 160);
  check(first && first.t - jumpT < 20, `jump: first 165 Hz trace point at +${first && Math.round(first.t - jumpT)} ms`);
  check(trace.filter((p) => p.hz > 160).length > 80, 'jump: 165 Hz section missing from trace');
}

// A spike right at the onset can't start the hum at the wrong pitch.
{
  const { segs, trace } = runTracker(frames([[300, 0], [100, 61], [2000, jitter(130)], [400, 0]]));
  check(segs.length === 1 && inBand(trace, 128, 132), `onset spike: ${segs.length} hums, trace ${trace[0] && trace[0].hz.toFixed(1)}`);
}

/* ---------- Full pipeline: synthesized audio with breath bursts, through YIN and the tracker ---------- */
function renderScript(sr, script, opts = {}) {
  const yinN = createYin(sr).N;
  const totalMs = script.reduce((a, s) => a + s[0], 0);
  const n = Math.ceil(totalMs / 1000 * sr) + yinN;
  const sig = new Float32Array(n);
  let ph = 0, idx = yinN;
  const phases = HUM.map(() => rand() * 6.283);
  for (let i = 0; i < yinN; i++) sig[i] = 0.0005 * gauss();
  for (const [ms, f] of script) {
    const cnt = Math.round(ms / 1000 * sr);
    for (let i = 0; i < cnt && idx < n; i++, idx++) {
      let s = 0;
      if (f) {
        ph += 2 * Math.PI * f / sr;
        const env = Math.min(1, i / (0.05 * sr), (cnt - i) / (0.05 * sr));
        for (let k = 0; k < HUM.length; k++) s += HUM[k] * Math.sin((k + 1) * ph + phases[k]);
        s *= 0.05 * env;
      }
      sig[idx] = s + 0.0005 * gauss();
    }
  }
  // Breath/handling bursts: 40 ms of strong low-frequency rumble.
  for (const atMs of opts.bursts || []) {
    let y = 0;
    const s0 = yinN + Math.round(atMs / 1000 * sr);
    for (let i = 0; i < 0.04 * sr && s0 + i < n; i++) { y += (gauss() - y) * 0.02; sig[s0 + i] += 0.6 * y; }
  }
  return { sig, totalMs, yinN };
}

{
  const sr = 16000, yin = createYin(sr);
  const script = [[2000, 0], [3000, 130.4], [500, 0], [2000, 145], [400, 0], [300, 130], [1200, 0], [2500, 127.5], [800, 0]];
  const { sig, totalMs } = renderScript(sr, script, { bursts: [2600, 3400, 4300, 9100] });
  const segs = [], trace = [];
  const tr = createTracker(() => 130, { end: (s) => segs.push(s), frame: (t, hz) => trace.push({ t, hz }), retract: retractFrom(trace) });
  for (let t = 0; t <= totalMs; t += 1000 / 60) {
    const end = yin.N + Math.floor(t / 1000 * sr);
    tr.push(t, yin.detect(sig.subarray(0, Math.min(sig.length, end))), false);
  }
  tr.flush();
  console.log('pipeline segments:', segs.map((s) => ({ dur: Math.round(s.dur), hz: +s.hz.toFixed(2), score: s.score, ok: s.ok, lock: Math.round(s.lockMs) })));
  check(segs.length === 3, `pipeline: expected 3 hums (300 ms blip ignored), got ${segs.length}`);
  if (segs.length === 3) {
    check(Math.abs(segs[0].dur - 3000) < 150 && segs[0].ok && segs[0].score >= 95, 'pipeline: hum 1 should be ~3 s, ok, score >= 95');
    check(!segs[1].ok && segs[1].score < 15, 'pipeline: hum 2 at 145 Hz should fail');
    check(segs[2].ok && segs[2].score > 55 && segs[2].score < 80, 'pipeline: hum 3 at 127.5 Hz (~33c low) should pass with a mid score');
  }
  const stray = trace.filter((p) => !((p.hz > 127 && p.hz < 133) || (p.hz > 124 && p.hz < 129) || (p.hz > 141 && p.hz < 149)));
  check(stray.length === 0, `pipeline: ${stray.length} trace points away from the hummed pitches (${stray.map((p) => p.hz.toFixed(1)).join(',')})`);
}

/* ---------- PCM analyzer (iPhone app path): chunk size must not change the result ---------- */
{
  const sr = 16000;
  const script = [[800, 0], [2500, 130], [600, 0], [1500, 160], [600, 0]];
  const { sig, totalMs } = renderScript(sr, script, { bursts: [1500] });
  const results = {};
  for (const chunk of [128, 512, 1600, 4800]) {
    const segs = [], times = [];
    const tr = createTracker(() => 130, { end: (s) => segs.push(s) });
    const pcm = createPcmAnalyzer(sr, (t, r) => { times.push(t); tr.push(t, r, false); });
    const t0 = 10000;
    for (let i = 0; i < sig.length; i += chunk) {
      const part = sig.subarray(i, Math.min(sig.length, i + chunk));
      // Arrival time: when the chunk's last sample was captured, plus 0–25 ms of delivery jitter.
      pcm.push(part, t0 + (i + part.length) / sr * 1000 + rand() * 25);
    }
    tr.flush();
    const mono = times.every((t, i) => i === 0 || t > times[i - 1]);
    const rate = times.length / (totalMs / 1000);
    results[chunk] = segs.map((s) => [Math.round(s.dur / 50) * 50, +s.hz.toFixed(1), s.score]);
    check(mono, `pcm chunk ${chunk}: timestamps not increasing`);
    check(rate > 55 && rate < 70, `pcm chunk ${chunk}: ${rate.toFixed(1)} detections/s`);
    check(segs.length === 2, `pcm chunk ${chunk}: expected 2 hums, got ${segs.length}`);
    if (segs.length === 2) {
      check(segs[0].ok && segs[0].score >= 97 && Math.abs(segs[0].dur - 2500) < 150, `pcm chunk ${chunk}: hum 1 ${JSON.stringify(results[chunk][0])}`);
      check(!segs[1].ok && Math.abs(segs[1].hz - 160) < 0.5, `pcm chunk ${chunk}: hum 2 ${JSON.stringify(results[chunk][1])}`);
    }
  }
  console.log('pcm segments by chunk size:', JSON.stringify(results));

  // A stall (no audio for 2 s, then audio resumes) re-anchors the clock and ends the hum instead of bridging it.
  const segs = [];
  const tr = createTracker(() => 130, { end: (s) => segs.push(s) });
  const pcm = createPcmAnalyzer(sr, (t, r) => tr.push(t, r, false));
  const tone = synth(sr, sr * 2, 130, HUM, 0.0005);
  for (let i = 0; i < tone.length; i += 1600) pcm.push(tone.subarray(i, i + 1600), (i + 1600) / sr * 1000);
  for (let i = 0; i < tone.length; i += 1600) pcm.push(tone.subarray(i, i + 1600), 4000 + (i + 1600) / sr * 1000);
  tr.flush();
  check(segs.length === 2, `pcm stall: expected the gap to split the hum in two, got ${segs.length}`);
}

console.log(`${total - fails}/${total} checks passed`);
process.exit(fails ? 1 : 0);
