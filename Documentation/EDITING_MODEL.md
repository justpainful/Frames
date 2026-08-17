# The editing model

## One document

`EditDocument` is a `Codable`, `Hashable` value type that describes an entire
edit. Preview and export both consume it. Nothing visible in the editor lives
outside it, which is what makes these three properties true at once:

- **Non-destructive.** Source files are copied into the session and never
  written to. Every operation rewrites numbers in the document.
- **Undoable.** Undo is restoring a previous value of one struct.
- **Recoverable.** Crash recovery is writing that struct to disk.

## Clips own no pixels

```swift
struct VideoClip {
    var assetID: UUID
    var source: TimeRange     // in-point and length in the source
    var speed: Double
    var isReversed: Bool
    var freezeDuration: TimeInterval?
    …
}
```

Trim moves `source.start` and `source.duration`. Split produces two clips
pointing at the same asset. Removing a range rewrites the clips it touches and
drops the ones it covers. None of these decode a frame or write a byte, which is
why they are instant and lossless.

A freeze frame is a clip with `freezeDuration` set rather than a separate type,
so trim, split, remove range and reorder work on it with no special cases. At
composition time it becomes one source frame scaled to the held duration.

## Remove Range

The operation the app is built around. Splitting twice and deleting the middle is
the single most common piece of busywork in mobile video editors, so Frames does
it directly:

```
0      3          8           15
───────┠━━━━━━━━━━┨────────────
         REMOVE
                ↓
0      3           10
────────────────────
```

`EditDocument.removeRange(_:)` walks the track once. For each clip it takes the
intersection with the removed span and does one of four things: keep it, drop it,
trim one side, or split around it. Then everything positioned in timeline time —
audio, text, overlays, blur, effects, tracking samples — shifts back by the
removed duration, so the edit stays in sync. Layers whose whole life was inside
the removed span are deleted, because there is no longer a moment at which they
could be seen.

Audio that straddles the span is shortened rather than split, so a music bed
stays anchored where it was placed.

## Grade versus clip properties

Adjustments, filters and effects are document-level: they are a *look* for the
edit, which is how the Adjust and Filters tools behave. Trim, speed, volume,
crop, transform and transitions are per clip. This split is why the contextual
toolbar for a selected clip contains no colour controls — they were never a
property of a clip.

## Coordinate space

Everything positional is normalized: 0...1, top-left origin, y down. A text
overlay placed on a 1080p preview lands in exactly the same place in a 4K export
because nothing in the document is in pixels.

`CoordinateSpaceConverter` holds the only two conversions: to Core Image's
bottom-left pixel space, and to and from Vision's bottom-left normalized space.

## Undo

`EditorHistory` stores whole-document snapshots. The document is a few kilobytes
of value types and every operation is a pure mutation of it, so a snapshot is
cheap and — unlike hand-written inverse commands — cannot drift out of sync with
the operation it is supposed to reverse.

Continuous gestures coalesce through a token: `perform(_:coalescing:)` with the
same non-nil token reuses the pending entry, and `endInteraction()` closes the
group. One slider drag is one undo step.

Every mutation in the app goes through `EditorSession.perform`. That is the
enforcement mechanism: there is no other way to change the document, so there is
no way to make a change that is not undoable and not autosaved.

## Keyframes

`KeyframeSet` holds sparse per-property tracks. A layer with no keyframes
evaluates to its static value for free, so the animated path costs nothing when
it is unused. Direct manipulation always sets the value; a keyframe is only
created when the user taps the diamond.

## Session recovery

`SessionRecoveryStore` is an actor that writes one document, atomically, to
Application Support. On launch the app offers to continue or discard. Exporting
or discarding deletes it. There is exactly one, it is never named, and it never
appears in a list — this is crash recovery, not a project system.

A stored document is discarded rather than half-restored if its schema version
does not match or if its media is missing.
