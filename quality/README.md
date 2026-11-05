# Audio quality check

`web/audio-quality.js` looks at a recording and estimates its real quality. It reports whether the audio came from a lossy
file (MP3, AAC, Vorbis, Opus) and at roughly what bitrate, whether it was upsampled from a lower sample rate, and how
many bits of each sample are real. It still works after the audio has been converted to 32-bit float at 48 kHz, as
Audio Scratchpad records it.

It's a single file of plain JavaScript with no dependencies, and all three versions of the app use it to label each
recording:

- **Web:** the browser version runs the file in a worker. It lives in `web/` so that the site serves it.
- **Mac:** the app runs the file in JavaScriptCore, which comes with macOS (`mac/Quality.swift`). `mac/build.sh` copies
  it into the app.
- **Windows:** the app runs the file in Chakra, the JavaScript engine built into Windows 10 and 11
  (`windows/Quality.cs`). `windows/build.cmd` builds it into the exe.

Each app's self-check runs two made-up recordings through its own copy, which catches mistakes in how audio is passed to
the script.

```js
// Browser: <script src="audio-quality.js"></script> (or importScripts in a worker) defines AudioQuality.
// Node: const AudioQuality = require("./web/audio-quality.js");
const report = AudioQuality.analyze([audioBuffer.getChannelData(0), audioBuffer.getChannelData(1)], audioBuffer.sampleRate);
report.verdict; // "lossless", "lossy", "upsampled" or "silent"
report.label; // "Lossless", the estimated bitrate e.g. "96-160 kbps" (or "Lossy" if it can't be estimated), or a source sample rate below 44.1 kHz e.g. "22.05 kHz"
report.summary; // e.g. "Likely from a lossy file at about 96-160 kbps: it cuts off sharply at 16.1 kHz, ..."
report.tooltip; // e.g. "Estimated bitrate, based on the source material."
```

Long recordings don't need to be read whole. `excerptRanges(frames, sampleRate)` lists which parts to read: 24 parts of
1.5 seconds, spread through the file, or the whole file if it's shorter than that. `analyzeExcerpts(samples, channels,
sampleRate, ranges)` takes those parts back to back as one interleaved `Float32Array`. On real recordings it gave the
same verdicts as reading the whole file, and takes about a second however long the recording is.

The report also includes the measurements behind the verdict: `bandwidth` (cutoff frequency and whether it's a brick
wall), `lossy` (hole share, reason, bitrate range), `sourceSampleRate`, `bitDepth` and `stereo`.

## How it works

- **Cutoff:** lossy encoders and resamplers both cut the high frequencies off with a brick wall, while natural
  recordings roll off gradually. A resampler cuts at about 97% of half the old sample rate (for example 21.4 kHz for
  44.1 kHz audio). Encoders cut wherever their bitrate allows (for example about 16 kHz for 128 kbps MP3). So the
  position of the wall tells the two apart, and for lossy files it gives a rough bitrate.
- **Holes:** in the high frequencies, lossy encoders switch off bands that they judge inaudible, frame by frame. That
  leaves short gaps that real recordings, which always have some noise there, don't have. Each frequency is compared
  with its own usual level, so music that simply fades towards its cutoff doesn't count. This decides the cases where
  the cutoff alone can't.
- **Bit depth:** if nothing has processed the samples since conversion, 16-bit audio stored as float still sits on a
  grid of 1/32768 steps.

## Testing

`make-corpus.sh` takes a lossless recording and makes degraded copies of it: MP3, AAC, Opus and Vorbis at a range of
bitrates, lower sample rates and lower bit depths. Every copy is saved as 32-bit float 48 kHz WAV. `score-corpus.js`
then checks the verdict for each copy. Both scripts need ffmpeg, and `cli.js` analyses any file.

```sh
quality/make-corpus.sh some-lossless-file.flac /tmp/corpus
node quality/score-corpus.js /tmp/corpus
node quality/cli.js recording.wav
```

### Results

The script was tested on five real lossless recordings from archive.org: four 24-bit live concert recordings (three at
48 kHz, one at 96 kHz) and a 24-bit/96 kHz orchestral recording.

- **Corpus:** 134 of 135 verdicts were right. The miss was a 256 kbps AAC file that the check called "upsampled from
  44.1 kHz". At that bitrate, AAC cuts in the same place a 44.1 kHz recording does and fills its gaps with noise, so
  the two look alike.
- **Held-out files:** all 28 encodes the thresholds weren't tuned on were right. They included MP3s made with a
  different encoder (shine), MP3 encoded twice, mono MP3, AAC and MP3 encoded directly at 48 kHz, 32 kbps Opus, and
  plain 16-bit CD-quality copies.
- **Lossless sources:** none of the sources was flagged, including a noisy chiptune that has content up to 24 kHz.
- **Real files:** the check found an MP3 cutoff at 16 kHz in a "lossless" live FLAC from 2000. The spectrogram
  confirms it: a 16 kHz wall with the spikes MP3 leaves up to 17 kHz.

The hole measure was later changed to ignore fades, after it flagged lossless Spotify recordings and a known lossless
master as 256+ kbps. That version was scored on 86 files: three lossless masters and their encodes, eight real MP3s and
two Spotify lossless recordings. Those five archive.org recordings haven't been re-scored with it.

- **Fixed:** every lossless source and its 16-bit and 24-bit copies now read as lossless. Before, several read as lossy.
- **Still caught:** all eight real MP3s and every MP3, Opus and AAC encode except one 256 kbps AAC file.
- **Not settled:** files resampled down to 16 or 32 kHz, and one to 44.1 kHz, got a bitrate label instead of their
  sample rate or "Lossless". The same happened before the change. This run used ffmpeg's built-in resampler rather than
  soxr, which may be the cause.

### Limits

- **High-bitrate AAC and Opus:** these leave no gaps. They're caught only by their cutoff, and AAC at 256 kbps and
  above can pass as clean 44.1 kHz audio.
- **Bitrate is a range:** the same cutoff means different bitrates in different encoders, and LAME's MP3 cutoff also
  moves with the music.
- **Bit depth:** usually unknown after resampling or volume changes, because they erase the grid.
- **Proof:** a check like this can show that a file is worse than it claims, but never prove that it's as good as it
  claims.
