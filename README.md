# ClipboardKit

A lightweight clipboard history + screenshot + image-annotation tool for macOS.
Runs as a menu bar app.

## Features

### Clipboard history
- Captures text, images, and files
- SQLite-backed history with debounced async saves and a thumbnail cache
- Large-text sidecar files to keep the DB small
- Search across history
- Pin items (persisted, exempt from trim)
- Drag in / drag out of the popover (files, images, text)
- Auto-fetched link previews (title + image + favicon) for URL items
- Configurable max history size, large-file threshold, and storage location
- Optional "restore previous clipboard" after pasting
- Per-row actions: paste, copy, Quick Look, OCR, annotate, Reveal in Seeker, delete

### Screenshots
- Capture region (default **⌘⇧S**)
- Long (scrolling) screenshot via auto-stitching (default **⌘⇧L**)
- Full-screen capture (opt-in shortcut)
- Window capture (opt-in shortcut)
- Native-pixel PNGs (no Retina downscaling)
- Thumbnail HUD with one-click "open annotator" entry point

### Image annotator
- Tools: arrow, rectangle, oval, text, pen, highlighter, callout, redact,
  blur, torn-blur, crop
- Custom color picker
- Border-blur and torn-edge frame actions
- OCR via Vision (in-annotator and from the history context menu)
- Auto-saves back to the source file on close; **⌘C** copies the annotated
  image to the clipboard
- Undo / redo

### Other
- Quick Look image preview (system `QLPreviewPanel`)
- Configurable global hotkeys with an in-app recorder
- Optional launch at login

## Default hotkeys

| Action                     | Default |
| -------------------------- | ------- |
| Toggle clipboard history   | ⌘⇧V    |
| Capture screen region      | ⌘⇧S    |
| Long (scrolling) screenshot| ⌘⇧L    |
| Capture full screen        | — (opt-in) |
| Capture window             | — (opt-in) |

Full-screen and window capture have no default binding to avoid clashing with
macOS's built-in `⌘⇧3` / `⌘⇧4` shortcuts; set your own in Settings.

## Requirements

- macOS 26.0+
- Xcode 17+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
xcodegen generate
xcodebuild -project ClipboardKit.xcodeproj \
           -scheme ClipboardKit \
           -configuration Release \
           -derivedDataPath .build/xcode \
           -destination 'platform=macOS' \
           build
```

The built app will be at
`.build/xcode/Build/Products/Release/ClipboardKit.app`.

## Install

```bash
cp -R .build/xcode/Build/Products/Release/ClipboardKit.app /Applications/
open /Applications/ClipboardKit.app
```

## Usage

1. Launch **ClipboardKit** — it runs as a menu bar app
2. Press **⌘⇧V** to open the clipboard history panel
3. Click any item to paste it, or hover for inline actions
4. Use the gear icon to open Settings (hotkeys, history size, storage path,
   launch at login, restore-clipboard behavior)
