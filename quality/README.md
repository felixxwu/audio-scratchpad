# Audio quality check

`audio-quality.js` looks at a recording and estimates its real quality. It reports whether the audio came from a lossy
file (MP3, AAC, Vorbis, Opus) and at roughly what bitrate, whether it was upsampled from a lower sample rate, and how
many bits of each sample are real. It still works after the audio has been converted to 32-bit float at 48 kHz, as
Audio Scratchpad records it.

It's a single file of plain JavaScript with no dependencies, so the same code can run in the browser version, in Node,
and inside the Mac and Windows apps through an embedded JavaScript engine.

```js
// Browser: <script src="audio-quality.js"></script> defines AudioQuality.
// Node: const AudioQuality = require("./audio-quality.js");
const report = AudioQuality.analyze([audioBuffer.getChannelData(0), audioBuffer.getChannelData(1)], audioBuffer.sampleRate);
report.verdict; // "lossless", "lossy", "upsampled" or "silent"
report.summary; // e.g. "Likely from a lossy file at about 96-160 kbps: it cuts off sharply at 16.1 kHz, ..."
```

The report also includes the measurements behind the verdict: `bandwidth` (cutoff frequency and whether it's a brick
wall), `lossy` (hole share, reason, bitrate range), `sourceSampleRate`, `bitDepth` and `stereo`.

## How it works

- **Cutoff:** lossy encoders and resamplers both cut the high frequencies off with a brick wall, while natural
  recordings roll off gradually. A resampler cuts at about 97% of half the old sample rate (for example 21.4 kHz for
  44.1 kHz audio). Encoders cut wherever their bitrate allows (for example about 16 kHz for 128 kbps MP3). So the
  position of the wall tells the two apart, and for lossy files it gives a rough bitrate.
- **Holes:** in the high frequencies, lossy encoders switch off bands that they judge inaudible, frame by frame. That
  leaves short gaps that real recordings, which always have some noise there, don't have. This decides the cases where
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

### Limits

- **High-bitrate AAC and Opus:** these leave no gaps. They're caught only by their cutoff, and AAC at 256 kbps and
  above can pass as clean 44.1 kHz audio.
- **Bitrate is a range:** the same cutoff means different bitrates in different encoders, and LAME's MP3 cutoff also
  moves with the music.
- **Bit depth:** usually unknown after resampling or volume changes, because they erase the grid.
- **Proof:** a check like this can show that a file is worse than it claims, but never prove that it's as good as it
  claims.
