# Clipboard History

A lightweight clipboard history manager for macOS.

## Features

- Tracks text and image clipboard history
- Quick access via **⌘⇧V**
- Search through clipboard history
- Configurable max history size (1–1000 items)
- Large file storage with configurable threshold
- Optional launch at login
- Menu bar app (runs in background)

## Requirements

- macOS 26.0+
- Xcode 15.0+

## Build

```bash
xcodegen generate
xcodebuild -scheme ClipboardHistory -configuration Release -derivedDataPath build build
```

The built app will be at `build/Build/Products/Release/ClipboardHistory.app`.

## Install

Copy the app to `/Applications`:

```bash
cp -R build/Build/Products/Release/ClipboardHistory.app /Applications/
```

## Usage

1. Launch **ClipboardHistory** — it runs as a menu bar app
2. Press **⌘⇧V** to open the clipboard history panel
3. Click any item to paste it
4. Use the gear icon to open Settings
