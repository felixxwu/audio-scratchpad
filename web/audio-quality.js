// Estimates the real quality of a recording: whether it came from a lossy file (MP3, AAC and so on) and roughly at what
// bitrate, whether it was upsampled from a lower sample rate, and how many bits of the samples are real.
//
// It has no dependencies and uses only plain JavaScript, so the same file works in a browser page (it defines
// window.AudioQuality), in Node (require it), and in an embedded engine such as JavaScriptCore or a WebView.
//
//   const report = AudioQuality.analyze([leftFloat32Array, rightFloat32Array], 48000);
//   report.verdict   // "lossless", "lossy", "upsampled" or "silent"
//   report.label     // a few words for a list row, such as "96-160 kbps", "Lossless" or "22.05 kHz"
//   report.summary   // a sentence describing what was found
//   report.tooltip   // a short note on what the label means, for hovering over it
//
// Long recordings don't need to be read whole. excerptRanges(frames, sampleRate) says which parts of a file to read
// (about 36 seconds in all, spread through it), and analyzeExcerpts takes those parts back to back as interleaved
// samples. That form also suits native apps, which can hand over a single Float32Array from a file.
//
// Everything is an estimate from traces the source left in the audio. A file can be shown to be worse than it claims,
// but never proven to be as good as it claims.
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.AudioQuality = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  // Lossy encoders low-pass the audio harder the lower the bitrate. These ranges come from encoding real music with
  // LAME (MP3), ffmpeg's AAC, Vorbis and Opus: the same cutoff can mean different bitrates in different encoders, and
  // mono files get more bandwidth for the same bitrate, so the bitrate is only a rough guide.
  var LOSSY_CUTOFFS = [
    { below: 9000, label: "a very low bitrate (48 kbps or less)", short: "Up to 48 kbps" },
    { below: 13000, label: "a low bitrate (about 64 kbps)", short: "~64 kbps" },
    { below: 16500, label: "about 96-160 kbps", short: "96-160 kbps" },
    { below: 18000, label: "about 128-160 kbps", short: "128-160 kbps" },
    { below: 19600, label: "about 160-224 kbps", short: "160-224 kbps" },
    { below: 20000, label: "about 192-320 kbps", short: "192-320 kbps" },
    { below: 20450, label: "about 192-320 kbps, or Opus at any bitrate", short: "192-320 kbps" },
    { below: Infinity, label: "a high bitrate (256 kbps or more)", short: "256+ kbps" },
  ];

  // Common sample rates. A cutoff just below half of one of these suggests the audio was recorded or saved at that rate.
  var SAMPLE_RATES = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000];

  var MAX_FRAMES = 1500; // spread over all the audio given, so long files take no longer than about 70 seconds would
  var SILENT_DB = -70; // frames quieter than this (RMS, dBFS) are skipped
  var EXCERPT_SECONDS = 1.5;
  var EXCERPT_COUNT = 24;

  // Share of high-frequency bins that are holes. Lossless and resampled music measured 0.06-0.15%; MP3 about 0.9-8%.
  var HOLES_AT_STANDARD_CUTOFF = 0.008;
  var HOLES_WITHOUT_CUTOFF = 0.012;

  // `channels` holds one Float32Array per channel.
  function analyze(channels, sampleRate) {
    if (!channels || !channels.length) throw new Error("No audio channels given");
    for (var c = 1; c < channels.length; c++) {
      if (channels[c].length !== channels[0].length) throw new Error("All channels must have the same length");
    }
    return analyzeParts([channels], channels.length, sampleRate);
  }

  // The parts of a recording `frames` long that analyzeExcerpts needs, as [start, length, start, length, ...] in frames.
  function excerptRanges(frames, sampleRate) {
    var length = Math.round(EXCERPT_SECONDS * sampleRate);
    if (frames <= length * EXCERPT_COUNT) return [0, frames];
    var ranges = [];
    for (var i = 0; i < EXCERPT_COUNT; i++) {
      ranges.push(Math.floor((i * (frames - length)) / (EXCERPT_COUNT - 1)), length);
    }
    return ranges;
  }

  // `samples` holds the parts named by `ranges` back to back, each as interleaved frames.
  function analyzeExcerpts(samples, channelCount, sampleRate, ranges) {
    if (!(channelCount > 0)) throw new Error("Channel count must be a positive number");
    var parts = [];
    var offset = 0;
    for (var r = 1; r < ranges.length; r += 2) {
      var frames = Math.min(ranges[r], Math.floor((samples.length - offset) / channelCount));
      var channels = [];
      for (var c = 0; c < channelCount; c++) channels.push(new Float32Array(frames));
      for (var f = 0; f < frames; f++) {
        for (c = 0; c < channelCount; c++) channels[c][f] = samples[offset + f * channelCount + c];
      }
      parts.push(channels);
      offset += frames * channelCount;
    }
    return analyzeParts(parts, channelCount, sampleRate);
  }

  function analyzeParts(parts, channelCount, sampleRate) {
    if (!(sampleRate > 0)) throw new Error("Sample rate must be a positive number");
    var report = {
      sampleRate: sampleRate,
      channels: channelCount,
      verdict: "lossless",
      label: "",
      summary: "",
      tooltip: "",
      bandwidth: null,
      lossy: null,
      sourceSampleRate: null,
      bitDepth: measureBitDepth(parts),
      stereo: measureStereo(parts),
    };

    var spectra = measureSpectra(parts, sampleRate);
    if (!spectra) {
      report.verdict = "silent";
      report.summary = "The recording is too quiet or too short to judge its quality.";
      report.tooltip = report.summary;
      return report;
    }

    var cutoff = findCutoff(spectra);
    report.bandwidth = cutoff;
    var lossy = measureLossiness(spectra, cutoff);
    report.lossy = lossy;

    // A resampler's filter cuts at about 97% of the old Nyquist frequency, so a wall there means a lower sample rate. A
    // wall anywhere else is almost always an encoder's low-pass. Holes then tell apart the two cases that overlap:
    // high-bitrate encodes that cut near 21.5 kHz, like 44.1 kHz audio does.
    if (cutoff.brickWall) {
      var rate = matchSampleRate(cutoff.hz, sampleRate);
      if (rate && lossy.holes < HOLES_AT_STANDARD_CUTOFF) {
        report.verdict = rate < sampleRate ? "upsampled" : "lossless";
        report.sourceSampleRate = rate;
      } else if (rate || cutoff.hz < 0.95 * Math.min(sampleRate / 2, 22050)) {
        lossy.likely = true;
        lossy.reason = rate ? "holes" : "cutoff";
      }
    } else if (lossy.holes >= HOLES_WITHOUT_CUTOFF) {
      lossy.likely = true;
      lossy.reason = "holes";
    }
    if (lossy.likely) {
      report.verdict = "lossy";
      var estimate = cutoff.brickWall ? guessBitrate(cutoff.hz) : null; // no cutoff to judge it by
      lossy.bitrate = estimate && estimate.label;
      lossy.bitrateLabel = estimate && estimate.short;
    }

    report.label = report.verdict === "lossy" ? lossy.bitrateLabel || "Lossy"
      : report.verdict === "upsampled" && report.sourceSampleRate < 44100 ? report.sourceSampleRate / 1000 + " kHz"
      : "Lossless";
    report.summary = describe(report);
    report.tooltip = (report.verdict === "lossy" ? (lossy.bitrateLabel ? "Estimated bitrate" : "Estimated to be lossy")
      : report.verdict === "upsampled" && report.sourceSampleRate < 44100 ? "Estimated sample rate"
      : "Estimated to be lossless") + ", based on the source material.";
    return report;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Spectra

  // Returns short-time power spectra (in dB) of the mono mix at evenly spaced points through the file. Two sizes are
  // measured: long frames for an accurate frequency picture, and short ones (about the length of a lossy codec's own
  // frames) to see the holes that lossy coding leaves.
  function measureSpectra(parts, sampleRate) {
    var size = nextPowerOfTwo(sampleRate * 0.04); // 2048 at 48 kHz, about 23 Hz per bin
    var shortSize = nextPowerOfTwo(sampleRate * 0.01); // 512 at 48 kHz
    var length = 0;
    for (var p = 0; p < parts.length; p++) length += parts[p][0].length;
    if (length < size) return null;

    var hop = Math.max(size / 2, Math.floor((length - size) / MAX_FRAMES));
    var window = hann(size);
    var shortWindow = hann(shortSize);
    var fft = makeFft(size);
    var shortFft = makeFft(shortSize);
    var bins = size / 2 + 1;
    var shortBins = shortSize / 2 + 1;
    var mono = new Float64Array(size);
    var re = new Float64Array(size);
    var im = new Float64Array(size);
    var sre = new Float64Array(shortSize);
    var sim = new Float64Array(shortSize);
    var frames = [];
    var shortFrames = [];
    var scale = 1 / parts[0].length;
    var windowGain = sum(window) / 2;
    var shortGain = sum(shortWindow) / 2;
    var silent = Math.pow(10, SILENT_DB / 20);

    // Frames never straddle two parts, because the jump between them would sound like a click across every frequency.
    for (p = 0; p < parts.length; p++) {
      var channels = parts[p];
      for (var start = 0; start + size <= channels[0].length; start += hop) {
        measureFrame(channels, start);
      }
    }
    if (frames.length < 4) return null;

    return {
      sampleRate: sampleRate,
      frames: frames,
      binHz: sampleRate / size,
      bins: bins,
      shortFrames: shortFrames,
      shortBinHz: sampleRate / shortSize,
      shortBins: shortBins,
    };

    function measureFrame(channels, start) {
      var energy = 0;
      for (var i = 0; i < size; i++) {
        var v = 0;
        for (var c = 0; c < channels.length; c++) v += channels[c][start + i];
        v *= scale;
        mono[i] = v;
        energy += v * v;
      }
      if (Math.sqrt(energy / size) < silent) return;

      for (i = 0; i < size; i++) {
        re[i] = mono[i] * window[i];
        im[i] = 0;
      }
      fft(re, im);
      frames.push(toDb(re, im, bins, windowGain));

      // Two short frames from the middle of the long one.
      for (var part = 0; part < 2; part++) {
        var offset = (size >> 1) - shortSize + part * shortSize;
        for (i = 0; i < shortSize; i++) {
          sre[i] = mono[offset + i] * shortWindow[i];
          sim[i] = 0;
        }
        shortFft(sre, sim);
        shortFrames.push(toDb(sre, sim, shortBins, shortGain));
      }
    }
  }

  function toDb(re, im, bins, gain) {
    var out = new Float32Array(bins);
    var g = 1 / (gain * gain);
    for (var k = 0; k < bins; k++) {
      out[k] = 10 * Math.log10((re[k] * re[k] + im[k] * im[k]) * g + 1e-20);
    }
    return out;
  }

  // The level each frequency reaches in the loudest tenth of the file, which shows the bandwidth even in quiet music.
  function percentileSpectrum(frames, bins, fraction) {
    var out = new Float64Array(bins);
    var column = new Float64Array(frames.length);
    var index = Math.min(frames.length - 1, Math.floor(fraction * frames.length));
    for (var k = 0; k < bins; k++) {
      for (var f = 0; f < frames.length; f++) column[f] = frames[f][k];
      column.sort();
      out[k] = column[index];
    }
    return out;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Cutoff

  // Finds the frequency above which the spectrum drops sharply and stays down. Microphones, instruments and the ear's
  // own range make natural recordings roll off gradually; resamplers and lossy encoders cut with a brick wall.
  function findCutoff(spectra) {
    var binHz = spectra.binHz;
    var bins = spectra.bins;
    var nyquist = spectra.sampleRate / 2;
    var loud = smooth(percentileSpectrum(spectra.frames, bins, 0.9), Math.max(1, Math.round(100 / binHz)));

    var width = Math.max(2, Math.round(500 / binHz));
    var gap = Math.max(1, Math.round(150 / binHz));
    var first = Math.round(1000 / binHz);
    var last = bins - 1 - gap - width;

    // The noise floor is the quietest stretch of the spectrum, typically right below Nyquist.
    var floor = Infinity;
    for (var k = first; k + width < bins; k += width) floor = Math.min(floor, mean(loud, k, k + width));

    // A wall drops at least 20 dB from music well above the floor, and nothing above it comes back up. Walls must also
    // cut actual music: an MP3 resampled from 44.1 kHz shows the resampler's wall at 21.5 kHz too, but on what's left
    // above the encoder's cutoff, 90-110 dB under the music. Real walls measured at most 72 dB under it.
    var music = mean(loud, Math.round(500 / binHz), Math.round(4000 / binHz));
    var best = null;
    var run = null;
    for (k = first + width; k <= last + 1; k++) {
      var below = mean(loud, k - width, k);
      var above = mean(loud, k + gap, k + gap + width);
      var drop = below - above;
      var isWall = k <= last && drop >= 20 && below - floor >= 20 && below >= music - 80 &&
        max(loud, k + gap, bins) <= below - 0.6 * drop;
      if (isWall) {
        if (!run || drop > run.drop) run = { bin: k, drop: drop, below: below, above: above };
      } else if (run) {
        best = run; // the highest wall wins: lower ones are band edges inside the encoder's own bandwidth
        run = null;
      }
    }

    if (!best) {
      // The useful bandwidth: the highest frequency clearly above the noise floor (or, in noisy recordings with no quiet
      // stretch to measure a floor from, within 60 dB of the loudest frequency).
      var threshold = Math.min(floor + 10, max(loud, 0, bins) - 60);
      var top = 0;
      for (k = bins - 1; k > 0; k--) {
        if (loud[k] > threshold) {
          top = Math.min(nyquist, (k + 0.5) * binHz);
          break;
        }
      }
      return { hz: Math.round(top), brickWall: false, floorDb: round1(floor) };
    }

    // Put the cutoff where the level is halfway (in dB) between the music and the floor.
    var halfway = (best.below + Math.max(floor, best.above)) / 2;
    var edge = best.bin;
    for (k = best.bin + gap + width; k > first; k--) {
      if (loud[k] > halfway) {
        edge = k;
        break;
      }
    }
    var hz = Math.min(nyquist, (edge + 0.5) * binHz);
    return { hz: Math.round(hz), brickWall: true, dropDb: round1(best.drop), floorDb: round1(floor) };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Lossy coding

  // Lossy encoders throw away whatever they judge inaudible, frame by frame. In the high frequencies under the cutoff,
  // that leaves bins that drop to nothing for a moment while their neighbours are loud ("holes"), where real
  // recordings have continuous noise. MP3 and Vorbis leave plenty; AAC and Opus fill most of them with noise.
  function measureLossiness(spectra, cutoff) {
    var nyquist = spectra.sampleRate / 2;
    var top = cutoff.brickWall ? cutoff.hz : Math.min(nyquist, 20000);
    var high = top - 300;
    var low = Math.max(2500, top - 6000);
    var result = { likely: false, reason: null, holes: 0, bitrate: null };
    if (high - low < 1500) return result;

    var binHz = spectra.shortBinHz;
    var kLow = Math.ceil(low / binHz);
    var kHigh = Math.floor(high / binHz);
    var frames = spectra.shortFrames;
    var floor = cutoff.floorDb;

    // Only frames with real high-frequency content can show holes.
    var band = new Float64Array(kHigh - kLow + 1);
    var judged = [];
    for (var f = 0; f < frames.length; f++) {
      for (var k = kLow; k <= kHigh; k++) band[k - kLow] = frames[f][k];
      var level = Float64Array.from(band).sort()[band.length >> 1];
      if (level >= floor + 25) judged.push(frames[f]);
    }
    if (!judged.length) return result;

    // Music usually fades towards its cutoff, so each bin is judged against its own usual level, or the fade would count.
    var usual = percentileSpectrum(judged, spectra.shortBins, 0.5);

    // Holes: the share of bins more than 30 dB under that frame's median.
    var holeCount = 0;
    var cellCount = 0;
    for (f = 0; f < judged.length; f++) {
      for (k = kLow; k <= kHigh; k++) band[k - kLow] = judged[f][k] - usual[k];
      var median = Float64Array.from(band).sort()[band.length >> 1];
      for (k = 0; k < band.length; k++) {
        if (band[k] < median - 30) holeCount++;
      }
      cellCount += band.length;
    }
    result.holes = cellCount ? round4(holeCount / cellCount) : 0;
    return result;
  }

  function guessBitrate(hz) {
    for (var i = 0; i < LOSSY_CUTOFFS.length; i++) {
      if (hz < LOSSY_CUTOFFS[i].below) return LOSSY_CUTOFFS[i];
    }
  }

  // Resamplers put their filter's edge at about 97% of the old Nyquist frequency (94-98.5% across real recordings, as the
  // measured edge moves a little with the music).
  function matchSampleRate(hz, sampleRate) {
    for (var i = 0; i < SAMPLE_RATES.length; i++) {
      var rate = SAMPLE_RATES[i];
      if (rate > sampleRate) break;
      if (hz >= 0.94 * rate / 2 && hz <= 0.985 * rate / 2) return rate;
    }
    return null;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Bit depth and stereo

  // Fixed-point audio stored as float keeps its grid: every 16-bit sample is a whole multiple of 1/32768. Any gain change,
  // mixing or resampling after that breaks the grid, so a missing grid says little, but a present one is certain.
  function measureBitDepth(parts) {
    var depths = [8, 12, 16, 20, 24];
    var scales = depths.map(function (bits) {
      return Math.pow(2, bits - 1);
    });
    var fits = depths.length; // the grids from depths[depths.length - fits] up still hold
    var nonZero = 0;
    eachSample(parts, function (channels, i) {
      for (var c = 0; c < channels.length; c++) {
        var x = channels[c][i];
        if (x === 0) continue;
        nonZero++;
        // A sample on a coarse grid is on every finer one too, so only the coarsest remaining grid can fail.
        while (fits > 0) {
          var scaled = x * scales[depths.length - fits];
          if (scaled === Math.round(scaled)) break;
          fits--;
        }
      }
      return fits === 0; // nothing left to find
    });
    if (nonZero < 1000) return { bits: null, note: "Too few non-zero samples to tell." };
    if (fits > 0) {
      var bits = depths[depths.length - fits];
      return { bits: bits, note: "Every sample is a whole " + bits + "-bit value." };
    }
    return {
      bits: null,
      note: "Samples don't sit on a 24-bit or smaller grid, so the audio is float or was processed after conversion.",
    };
  }

  function measureStereo(parts) {
    if (parts[0].length < 2) return { identical: false, correlation: null };
    var ll = 0;
    var rr = 0;
    var lr = 0;
    var identical = true;
    eachSample(parts, function (channels, i) {
      var l = channels[0][i];
      var r = channels[1][i];
      ll += l * l;
      rr += r * r;
      lr += l * r;
      if (identical && Math.abs(l - r) > 1e-6) identical = false;
    });
    var correlation = ll > 0 && rr > 0 ? lr / Math.sqrt(ll * rr) : null;
    return { identical: identical, correlation: correlation === null ? null : round3(correlation) };
  }

  // Visits up to about 2 million frames, spread evenly over all the parts, until `visit` returns true.
  function eachSample(parts, visit) {
    var total = 0;
    for (var p = 0; p < parts.length; p++) total += parts[p][0].length;
    var step = Math.max(1, Math.floor(total / 2000000));
    for (p = 0; p < parts.length; p++) {
      var channels = parts[p];
      for (var i = 0; i < channels[0].length; i += step) {
        if (visit(channels, i)) return;
      }
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Description

  function describe(report) {
    var parts = [];
    var cut = report.bandwidth;
    var khz = function (hz) {
      return (hz / 1000).toFixed(1) + " kHz";
    };
    var rate = report.sourceSampleRate;
    if (report.verdict === "lossy") {
      if (!cut.brickWall) {
        parts.push("Likely from a lossy file: there's no single cutoff to judge the bitrate by, but it has the gaps lossy encoders leave.");
      } else if (report.lossy.reason === "holes") {
        parts.push("Likely from a lossy file at " + report.lossy.bitrate + ": it cuts off at " + khz(cut.hz) +
          " and has the gaps lossy encoders leave.");
      } else {
        parts.push("Likely from a lossy file at " + report.lossy.bitrate + ": it cuts off sharply at " + khz(cut.hz) +
          ", where lossy encoders cut rather than where a lower sample rate would.");
      }
    } else if (report.verdict === "upsampled") {
      parts.push("Upsampled from " + rate / 1000 + " kHz: it cuts off at " + khz(cut.hz) + " with no sign of lossy coding." +
        (rate >= 44100 ? " That loses nothing audible." : ""));
    } else if (cut.brickWall) {
      parts.push("Full bandwidth for " + report.sampleRate / 1000 + " kHz (cuts off at " + khz(cut.hz) +
        "), with no sign of lossy coding.");
    } else {
      parts.push("No sign of lossy coding or upsampling; content reaches " + khz(cut.hz) + ".");
    }
    var mono = report.channels === 1 || report.stereo.identical;
    if (report.verdict === "lossy" && cut.brickWall && mono) {
      parts.push("Mono files get more bandwidth for the same bitrate, so the real bitrate is probably lower than that.");
    }
    if (report.bitDepth.bits) parts.push("Samples are " + report.bitDepth.bits + "-bit.");
    if (report.stereo.identical) parts.push("Both channels are identical, so it's really mono.");
    return parts.join(" ");
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Helpers

  function makeFft(n) {
    var levels = Math.round(Math.log2(n));
    var cos = new Float64Array(n / 2);
    var sin = new Float64Array(n / 2);
    for (var i = 0; i < n / 2; i++) {
      cos[i] = Math.cos((2 * Math.PI * i) / n);
      sin[i] = Math.sin((2 * Math.PI * i) / n);
    }
    var rev = new Uint32Array(n);
    for (i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < levels; b++) r |= ((i >>> b) & 1) << (levels - 1 - b);
      rev[i] = r;
    }
    return function (re, im) {
      for (var i = 0; i < n; i++) {
        var j = rev[i];
        if (j > i) {
          var t = re[i];
          re[i] = re[j];
          re[j] = t;
          t = im[i];
          im[i] = im[j];
          im[j] = t;
        }
      }
      for (var size = 2; size <= n; size *= 2) {
        var half = size / 2;
        var step = n / size;
        for (var s = 0; s < n; s += size) {
          for (var k = 0; k < half; k++) {
            var a = s + k;
            var b = a + half;
            var wr = cos[k * step];
            var wi = -sin[k * step];
            var xr = re[b] * wr - im[b] * wi;
            var xi = re[b] * wi + im[b] * wr;
            re[b] = re[a] - xr;
            im[b] = im[a] - xi;
            re[a] += xr;
            im[a] += xi;
          }
        }
      }
    };
  }

  function hann(n) {
    var w = new Float64Array(n);
    for (var i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n);
    return w;
  }

  function nextPowerOfTwo(x) {
    var n = 1;
    while (n < x) n *= 2;
    return n;
  }

  function smooth(values, radius) {
    var out = new Float64Array(values.length);
    for (var i = 0; i < values.length; i++) out[i] = mean(values, i - radius, i + radius + 1);
    return out;
  }

  function mean(values, from, to) {
    from = Math.max(0, from);
    to = Math.min(values.length, to);
    var total = 0;
    for (var i = from; i < to; i++) total += values[i];
    return to > from ? total / (to - from) : -Infinity;
  }

  function max(values, from, to) {
    var m = -Infinity;
    for (var i = Math.max(0, from); i < Math.min(values.length, to); i++) if (values[i] > m) m = values[i];
    return m;
  }

  function sum(values) {
    var total = 0;
    for (var i = 0; i < values.length; i++) total += values[i];
    return total;
  }

  function round1(x) {
    return Math.round(x * 10) / 10;
  }

  function round4(x) {
    return Math.round(x * 10000) / 10000;
  }

  function round3(x) {
    return Math.round(x * 1000) / 1000;
  }

  return { analyze: analyze, excerptRanges: excerptRanges, analyzeExcerpts: analyzeExcerpts };
});
