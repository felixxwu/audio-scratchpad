#!/bin/sh
# Makes degraded copies of a lossless recording to test audio-quality.js against: lossy encodes at many bitrates,
# lower sample rates and lower bit depths. Every copy ends up as a 32-bit float 48 kHz WAV, like Audio Scratchpad's
# recordings, and is named after what was done to it ("mp3-128", "rate-22050" and so on).
# Usage: quality/make-corpus.sh source-audio out-dir [seconds]
set -eu
src=$1
out=$2
seconds=${3:-30}
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ff() { ffmpeg -hide_banner -loglevel error -nostdin -y "$@"; }
final() { ff -i "$1" -af aresample=48000:resampler=soxr -c:a pcm_f32le -ar 48000 "$out/$2.wav"; }

# The untouched reference, as float at 48 kHz.
ff -i "$src" -t "$seconds" -af aresample=48000:resampler=soxr -c:a pcm_f32le -ar 48000 "$tmp/ref.wav"
cp "$tmp/ref.wav" "$out/original.wav"
ff -i "$tmp/ref.wav" -ar 44100 -c:a pcm_s16le "$tmp/cd.wav"

for rate in 64 96 128 160 192 256 320; do
  ff -i "$tmp/cd.wav" -c:a libmp3lame -b:a ${rate}k "$tmp/mp3-$rate.mp3"
  final "$tmp/mp3-$rate.mp3" "mp3-$rate"
done
for q in 0 2 5; do
  ff -i "$tmp/cd.wav" -c:a libmp3lame -q:a $q "$tmp/mp3-v$q.mp3"
  final "$tmp/mp3-v$q.mp3" "mp3-v$q"
done
for rate in 64 128 192 256; do
  ff -i "$tmp/cd.wav" -c:a aac -b:a ${rate}k "$tmp/aac-$rate.m4a"
  final "$tmp/aac-$rate.m4a" "aac-$rate"
done
for rate in 48 96 160; do
  ff -i "$tmp/ref.wav" -c:a libopus -b:a ${rate}k "$tmp/opus-$rate.opus"
  final "$tmp/opus-$rate.opus" "opus-$rate"
done
for q in 2 6; do
  ff -i "$tmp/cd.wav" -c:a libvorbis -q:a $q "$tmp/vorbis-q$q.ogg"
  final "$tmp/vorbis-q$q.ogg" "vorbis-q$q"
done
for rate in 16000 22050 32000 44100; do
  ff -i "$tmp/ref.wav" -af aresample=$rate:resampler=soxr -c:a pcm_s16le -ar $rate "$tmp/rate-$rate.wav"
  final "$tmp/rate-$rate.wav" "rate-$rate"
done
# Lower bit depths, kept at 48 kHz so nothing else touches the samples.
ff -i "$tmp/ref.wav" -c:a pcm_s16le "$tmp/bits-16.wav"
ff -i "$tmp/bits-16.wav" -c:a pcm_f32le "$out/bits-16.wav"
ff -i "$tmp/ref.wav" -c:a pcm_s24le "$tmp/bits-24.wav"
ff -i "$tmp/bits-24.wav" -c:a pcm_f32le "$out/bits-24.wav"
# MP3 at 128 kbps, then turned down 3 dB like a DAW or player would, to check the lossy marks survive processing.
ff -i "$out/mp3-128.wav" -af volume=-3dB -c:a pcm_f32le "$out/mp3-128-quieter.wav"
