# Architecture

## The shape of the app

```
FramesApp
└── AppModel                  navigation + the one recoverable session
    ├── MediaChooserView      picker, files, recents
    └── EditorView
        ├── EditorSession     document + history + selection + playhead
        ├── EditorCanvasView  the media, and everything drawn over it
        ├── TimelineView      clips, playhead, zoom
        └── Tool surfaces     a function of EditorSession.selection
```

`AppModel` is deliberately thin. It knows two routes and owns one
`EditorSession`. It does not know what a clip is.

## The edit document

`EditDocument` is the single source of truth. It is a `Codable`, `Hashable`
value type holding:

- `assets` — every imported file, by id
- `videoTrack` — an ordered, gapless array of `VideoClip`
- `photo` — the still being edited, for photo documents
- `audioClips`, `textOverlays`, `imageOverlays`, `drawings`, `blurRegions`,
  `selectiveAdjustments`, `effects`, `trackedObjects`
- `grade` — adjustments and the chosen filter
- `background`, `outputAspect`, `audioMix`, `safeAreaGuides`

Nothing visible in the editor lives outside it. That is what makes preview and
export agree, what makes undo a one-line operation, and what makes crash
recovery a file write.

### Why snapshots for undo

`EditorHistory` stores whole-document snapshots rather than inverse commands.
The document is a few kilobytes of value types and every operation is a pure
mutation of it, so a snapshot is cheap and cannot drift out of sync with the
operation it is meant to reverse — which is the standard failure mode of
hand-written inverse commands in an editor with this many operation types.

Continuous gestures coalesce through a token, so dragging a slider for three
seconds is one undo step, not ninety.

Every mutation goes through `EditorSession.perform(_:coalescing:_:)`. Recording
the pre-change snapshot there rather than at each call site is what guarantees
nothing in the app can change the edit without being undoable.

### Why a clip owns no pixels

A `VideoClip` is an asset id plus a source range plus playback properties. Trim,
split and range removal only rewrite those numbers, which is why they are
instant, lossless and reversible. A freeze frame is modelled as a clip with a
`freezeDuration` rather than as a special case, so every timeline operation
works on it unchanged.

## Coordinate spaces

Positional data in the model is in **normalized composition space**: 0...1, top-left
origin, y down. That keeps edits resolution-independent, so a text overlay placed
on a 1080p preview lands in the same place in a 4K export.

Two conversions exist, each in exactly one place, in `CoordinateSpaceConverter`:

- to Core Image's bottom-left pixel space
- to and from Vision's bottom-left normalized space

## Concurrency

- `AppModel`, `EditorSession` and `PlaybackEngine` are `@MainActor @Observable`.
- Media work is `async` and off the main actor: `ImageLoader` and
  `SessionRecoveryStore` are actors; import, thumbnailing, waveform generation
  and Vision run in cancellable `Task`s.
- The `@Observable` classes avoid `willSet`/`didSet` on tracked properties; side
  effects are triggered explicitly from the mutating methods instead.

## Logging

Every expensive subsystem logs through a category in `FramesLog`, and
long-running work is bracketed with `OSSignposter` intervals so Instruments
shows it as intervals rather than point events.

## Error handling

`FramesError` carries a short user-facing title and message plus a separate
`logDescription` for the log. The interface never shows framework vocabulary or
error codes, and never fails silently.
