<h1 align="center">Audio Scratchpad</h1>

<p align="center">
  Record the sound of one app on Mac or Windows, then play it back or drag it straight into another app.
</p>

<p align="center">
  <img src="image.png" alt="Audio Scratchpad window showing Google Chrome as the source and three recordings with their waveforms" width="536">
</p>

## Features

- **Record one app:** capture a single app's audio without picking up the rest of your computer.
- **Start on the first sound:** recording begins at the first non-zero sample, so there's no silence to trim from the start.
- **Keep the full quality:** recordings are uncompressed 32-bit float WAV files at 48 kHz in stereo.
- **See every take:** each recording gets a waveform you can click or drag along to jump to any point.
- **Use it anywhere:** click the copy icon to copy the file, or drag the icon into another app.

Recordings are saved to `~/Music/Audio Scratchpad` on Mac and `Music\Audio Scratchpad` on Windows.

## Install

### Mac

You'll need an Apple Silicon Mac running macOS 14 or later.

1. Download the zip from the [latest release](https://github.com/felixxwu/audio-scratchpad/releases/latest).
2. Unzip it and move **Audio Scratchpad** to your Applications folder.
3. Open it. The app isn't notarized, so macOS will block it the first time. Go to **System Settings → Privacy & Security** and choose **Open Anyway**.
4. Allow **Screen & System Audio Recording** when asked. macOS uses this permission for app audio, and Audio Scratchpad doesn't save any video.

### Windows

You'll need Windows 10 version 2004 or later.

1. Download the `.exe` from the [latest release](https://github.com/felixxwu/audio-scratchpad/releases/latest).
2. Run it. There's nothing to install. The app isn't signed, so Windows may warn you the first time. Choose **More info → Run anyway**.

## Usage

1. Open the app you want to record and choose it under **Source**.
2. Click **Record**. The button shows "waiting for audio..." until the app makes a sound.
3. Click **Stop** when you're done, and the recording appears in the list.

Only apps with a Dock icon or a window are listed, so apps that run only from the menu bar or system tray won't appear.

## Build from source

### Mac

You'll need the Xcode command line tools, which you can install with `xcode-select --install`.

```sh
mac/build.sh
open ~/Applications/"Audio Scratchpad.app"
```

The script runs the self-checks, builds the app and installs it to `~/Applications`.

### Windows

You don't need to install anything, because the script uses the compiler that comes with Windows.

```bat
windows\build.cmd
"build\Audio Scratchpad.exe"
```

The script runs the self-checks and builds the app to `build`.

Every push to `main` and every pull request builds both apps and runs their self-checks. Publishing a GitHub release does the same and attaches the apps to that release.
