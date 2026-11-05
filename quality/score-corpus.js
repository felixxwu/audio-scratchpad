#!/usr/bin/env node
// Runs audio-quality.js over folders made by make-corpus.sh and counts how many verdicts match what was done to each
// file: "original" and "bits-*" should be lossless, "rate-*" upsampled (44.1 kHz and up count as lossless too), and
// everything else lossy. Usage: node quality/score-corpus.js corpus-dir...
"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const expected = (name) =>
  /^(original|bits-)/.test(name) ? ["lossless"] : /^rate-(44100|48000)/.test(name) ? ["upsampled", "lossless"]
    : /^rate-/.test(name) ? ["upsampled"] : ["lossy"];

let right = 0;
let total = 0;
for (const dir of process.argv.slice(2)) {
  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".wav")).sort().map((f) => path.join(dir, f));
  const out = execFileSync(process.execPath, [path.join(__dirname, "cli.js"), "--json", ...files]).toString();
  for (const line of out.trim().split("\n")) {
    const report = JSON.parse(line);
    const name = path.basename(report.file, ".wav");
    const ok = expected(name).includes(report.verdict);
    total++;
    if (ok) right++;
    const cut = report.bandwidth ? `${(report.bandwidth.hz / 1000).toFixed(1)}k${report.bandwidth.brickWall ? " wall" : ""}` : "";
    const detail = report.lossy?.bitrate || (report.sourceSampleRate ? `from ${report.sourceSampleRate} Hz` : "");
    console.log(`${ok ? "  " : "✗ "}${path.basename(dir)}/${name}`.padEnd(36), report.verdict.padEnd(10), cut.padEnd(11), detail);
  }
}
console.log(`\n${right}/${total} verdicts as expected`);
process.exit(right === total ? 0 : 1);
