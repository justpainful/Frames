# Frames

A native iOS photo and video editor.

Frames is built for one workflow: **choose media → edit → save**. There is no
project browser, no account, no cloud. Opening the app puts a photo or video in
front of you and gets out of the way, and the controls that appear are the ones
for whatever you just tapped.

- **Platform:** iPhone, iOS 26+
- **Language:** Swift
- **Interface:** SwiftUI (UIKit is bridged only for `AVPlayerLayer` and PencilKit)
- **Dependencies:** none at runtime

## Philosophy

Two ideas drive most of the design decisions in this repository.

**Contextual tools.** The bottom of the editor is a function of the current
selection. Select a clip and you get trim, split, speed, volume, crop. Select
text and you get font, colour, alignment, animation. Nothing is exposed until it
applies to something on screen, and nothing requires walking back out of a panel
to reach.

**One editing model.** Every visible change is data in `EditDocument`, and the
preview renderer and the export renderer both consume exactly that value. There
is no SwiftUI-only effect that vanishes on export, and no export-only behaviour
the preview cannot show. The source file is never modified.

## Repository layout

```
Frames/
├── Frames/                 App target
│   ├── App/                Entry point, root navigation, app-level state
│   ├── Model/              The edit document and every operation on it
│   ├── Import/             Photo picker, file import, recents
│   ├── Editor/             Session, history, selection, editor shell
│   ├── Canvas/             The media surface and what is drawn over it
│   ├── Timeline/           Clips, playhead, zoom, thumbnails
│   ├── Tools/              One folder per tool
│   ├── Engine/             Rendering, playback, composition
│   ├── Vision/             Face, person and object detection
│   ├── Audio/              Waveforms, mixing, voiceover
│   ├── Export/             Export settings, render, save to Photos
│   ├── Persistence/        Session recovery
│   ├── Components/         Shared views
│   ├── Support/            Logging, errors, test fixtures
│   └── Resources/          Assets and the string catalog
├── FramesTests/            Unit tests
├── FramesUITests/          UI smoke tests
├── Documentation/          Architecture notes
├── Scripts/                CI helpers and the app icon generator
└── .github/workflows/      macOS CI
```

## Building

Requires Xcode 26.6 or newer and an iOS 26 simulator or device.

```bash
xcodebuild build -project Frames.xcodeproj -scheme Frames \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

The Xcode project uses file-system-synchronised groups, so adding a Swift file
to a target directory adds it to the target — there is nothing to register.

## Tests

```bash
xcodebuild test -project Frames.xcodeproj -scheme Frames \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

Unit tests use Swift Testing and cover the parts where correctness is not
obvious by inspection: timeline math (trim, split, range removal, freeze
frames), undo and redo including gesture coalescing, adjustment ranges, and
session coding. UI tests use XCTest and enter the editor through a generated
fixture rather than the system photo picker:

```
-FRAMES_UI_TEST_FIXTURE sample-video
```

Fixtures are drawn at runtime and compiled out of release builds, so no media is
committed to this repository and no test depends on anyone's photo library.

## Continuous integration

`.github/workflows/ios.yml` runs on `macos-26`, selects Xcode 26.6, resolves an
iOS 26 simulator, then builds, tests, and runs repository hygiene checks. Result
bundles are uploaded when a run fails. See [Documentation/CI.md](Documentation/CI.md).

## Privacy

Everything happens on the device.

- No analytics, advertising or tracking SDKs. No third-party runtime dependencies at all.
- No account, no backend, no network calls with your media.
- Machine vision uses Apple's on-device frameworks.
- The photo picker is used in the mode that needs no library permission. Library
  access is only requested if you explicitly ask for the recents strip.
- Imported media is copied into the app's own container so an edit survives the
  original being deleted, and is removed when you export or discard.

## What is implemented

**Import and session**
Photo picker and Files import with automatic photo/video detection, an opt-in
recents strip that never asks for library access on launch, and single-session
crash recovery.

**Timeline** — video
Fixed centre playhead with the content moving under it, pinch zoom that holds the
playhead fixed, cached filmstrip thumbnails, tracks that appear only when used,
trim, split, remove range, duplicate, reorder, speed, freeze frames, real
reverse rendering, and transitions.

**Image processing**
Eighteen adjustments across Light, Color, Detail and Finishing; Auto Enhance that
measures the frame and writes ordinary editable sliders; twenty-three filters
built from primitives with real intensity interpolation; fifteen effects;
press-and-hold before/after.

**Blur and masks**
Full, area, face, person, background and tracked blur, in Gaussian, box, disc,
pixelate and mosaic. One mask engine shared by blur, selective adjustments and
effects, with feathering, inversion and keyframes.

**Portrait**
A multi-stage pass for people shot in poor light: chroma and luma denoise before
any exposure lift, gradual shadow recovery, edge-aware surface smoothing that
suppresses pores and micro-texture while structural detail is put back through
the same edge map, highlight-tied diffusion, and temporal stability so nothing
flickers during motion. It never changes anyone's shape.

**Overlays**
Text with fonts, weights, colour, alignment, tracking, line spacing, plates,
outlines, shadows and in/loop/out animations, laid out with Core Text so Arabic
shapes and reorders correctly. Image overlays with on-device background removal,
crop, corner radius, borders, shadows and blend modes. PencilKit drawing plus
arrow, line, rectangle and circle tools.

**Retouch**
Blemish healing that keeps the skin's own shading, red-eye correction, and a
small shadow lift. Tap to place, drag to move. No reshaping, ever.

**Audio**
Waveforms streamed off the main actor, volume, trim, split, fades, speed,
voiceover recording, lossless audio extraction from another video, and automatic
ducking implemented as editable mix automation.

**Export**
Resolution, frame rate and quality filtered against what the source can actually
provide, with codec, audio and colour behind Advanced. Real progress, save to
Photos with add-only permission, and the system share sheet.

## Known limitations

- iPhone only. The layout assumes one hand and a phone-sized canvas.
- Speed is a single rate per clip rather than a ramp. A speed curve would mean
  splitting a clip into segments at composition time, and the timeline model is
  clearer without that; per-clip speed plus split covers the same ground with
  one fewer concept.
- Filter and effect thumbnails are built from one sampled frame, so on a video
  they represent the frame at the playhead.

See [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for how the
pieces fit together, and the commit history for what has landed.
