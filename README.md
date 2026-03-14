# SpotifyPlay

A tiny macOS menu bar app that hijacks the play/pause media key so it controls **Spotify** instead of opening Apple Music every time you press play with nothing playing.

If you're tired of Apple Music launching itself uninvited, this fixes that.

## What it does

- Intercepts the play/pause key (keyboard, Touch Bar, headphones, etc.) and sends it to Spotify
- If Spotify is already open, it toggles play/pause
- If Spotify isn't running, it launches it and starts playing automatically
- Lives in the menu bar, stays out of your way
- Toggle it on/off from the menu bar icon
- Optional "Launch at Login" so you never think about it again

## Requirements

- macOS 11.0+
- Spotify installed

## Install (download — no build needed)

1. Go to the [latest release](https://github.com/HTMLGuyLLC/MacOSSpotifyPlay/releases/latest)
2. Download `SpotifyPlay.app.zip`
3. Unzip it
4. Drag `SpotifyPlay.app` into your `/Applications` folder

That's it. Works on both Apple Silicon and Intel Macs.

## Install (build from source)

If you'd rather build it yourself, you'll need Xcode Command Line Tools installed.

```bash
cd src
./build.sh
```

This compiles a universal binary (Apple Silicon + Intel) and outputs `SpotifyPlay.app` to the `dist/` folder. Then copy it to Applications:

```bash
cp -r dist/SpotifyPlay.app /Applications/
```

## Setup

Since the app isn't signed with an Apple Developer certificate, macOS will block it on first launch. To get past this:

1. Right-click (or Control-click) `SpotifyPlay.app` in Applications and choose **Open**
2. Click **Open** in the dialog that appears

You only need to do this once — after that it opens normally.

On first launch, macOS will also ask you to grant **Accessibility** permission. This is required for the app to intercept media keys.

1. Grant Accessibility access when prompted (System Settings > Privacy & Security > Accessibility)
2. Relaunch the app

That's it. Hit play and Spotify responds instead of Apple Music.

## Uninstall

```bash
rm -rf /Applications/SpotifyPlay.app
```

## How it works

It's a single Swift file that sets up a `CGEvent` tap to catch the system play key before macOS routes it to Apple Music. It uses AppleScript under the hood to talk to Spotify. A watchdog timer keeps things healthy and re-enables the tap if macOS disables it.

No dependencies, no frameworks to install, no package managers. Just Swift and native macOS APIs.

## License

MIT
