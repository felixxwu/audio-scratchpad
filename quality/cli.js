#!/usr/bin/env node
// Command-line front end for web/audio-quality.js. Reads WAV files directly; other formats are decoded with ffmpeg if it's
// installed. Usage: node quality/cli.js [--json] file...
"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { analyze } = require("../web/audio-quality.js");

function readWav(buffer) {
  if (buffer.toString("ascii", 0, 4) !== "RIFF" || buffer.toString("ascii", 8, 12) !== "WAVE") return null;
  let format = null;
  let offset = 12;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString("ascii", offset, offset + 4);
    let size = buffer.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === "fmt ") {
      let tag = buffer.readUInt16LE(body);
      if (tag === 0xfffe) tag = buffer.readUInt16LE(body + 24); // WAVE_FORMAT_EXTENSIBLE: real tag is in the GUID
      format = {
        tag,
        channels: buffer.readUInt16LE(body + 2),
        sampleRate: buffer.readUInt32LE(body + 4),
        bits: buffer.readUInt16LE(body + 14),
      };
    } else if (id === "data" && format) {
      if (size === 0 || size === 0xffffffff || body + size > buffer.length) size = buffer.length - body; // unfinished files
      return decodePcm(buffer.subarray(body, body + size), format);
    }
    offset = body + size + (size & 1);
  }
  return null;
}

function decodePcm(data, { tag, channels, sampleRate, bits }) {
  const bytes = bits / 8;
  const frames = Math.floor(data.length / (bytes * channels));
  const out = Array.from({ length: channels }, () => new Float32Array(frames));
  const read = {
    "1-8": (o) => (data[o] - 128) / 128,
    "1-16": (o) => data.readInt16LE(o) / 32768,
    "1-24": (o) => data.readIntLE(o, 3) / 8388608,
    "1-32": (o) => data.readInt32LE(o) / 2147483648,
    "3-32": (o) => data.readFloatLE(o),
    "3-64": (o) => data.readDoubleLE(o),
  }[tag + "-" + bits];
  if (!read) throw new Error(`Unsupported WAV format (tag ${tag}, ${bits}-bit)`);
  for (let f = 0, o = 0; f < frames; f++) {
    for (let c = 0; c < channels; c++, o += bytes) out[c][f] = read(o);
  }
  return { channels: out, sampleRate };
}

function decodeWithFfmpeg(file) {
  const probe = execFileSync("ffprobe", ["-v", "error", "-select_streams", "a:0", "-show_entries",
    "stream=sample_rate,channels", "-of", "csv=p=0", file]).toString().trim().split(",");
  const sampleRate = Number(probe[0]);
  const count = Number(probe[1]);
  const raw = execFileSync("ffmpeg", ["-v", "error", "-i", file, "-map", "0:a:0", "-f", "f32le", "-c:a", "pcm_f32le", "-"],
    { maxBuffer: 1 << 31 });
  const all = new Float32Array(raw.buffer, raw.byteOffset, raw.length / 4);
  const frames = Math.floor(all.length / count);
  const channels = Array.from({ length: count }, (_, c) => {
    const ch = new Float32Array(frames);
    for (let f = 0; f < frames; f++) ch[f] = all[f * count + c];
    return ch;
  });
  return { channels, sampleRate };
}

function load(file) {
  const buffer = fs.readFileSync(file);
  const wav = readWav(buffer);
  if (wav) return wav;
  try {
    return decodeWithFfmpeg(file);
  } catch (e) {
    throw new Error(`Not a WAV file, and ffmpeg couldn't decode it: ${e.message.split("\n")[0]}`);
  }
}

const args = process.argv.slice(2);
const json = args.includes("--json");
const files = args.filter((a) => a !== "--json");
if (!files.length) {
  console.error("Usage: node quality/cli.js [--json] file...");
  process.exit(2);
}
let failed = false;
for (const file of files) {
  try {
    const { channels, sampleRate } = load(file);
    const report = analyze(channels, sampleRate);
    if (json) console.log(JSON.stringify({ file, ...report }));
    else console.log(`${path.basename(file)}: ${report.verdict}\n  ${report.summary}`);
  } catch (e) {
    failed = true;
    console.error(`${path.basename(file)}: ${e.message}`);
  }
}
process.exit(failed ? 1 : 0);
