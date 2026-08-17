# Timeline

## Fixed playhead

The playhead sits at the centre of the view and the content moves under it.

Two things follow from that. Scrolling and scrubbing become one gesture, so
there is nothing to learn about which one you are doing. And the frame being
judged is always in the same place on screen, which matters when the judgement is
"is this the right frame to cut on".

`TimelineView` is gesture-driven rather than a `ScrollView`. A scroll view cannot
zoom around an arbitrary focal point without fighting its own content offset, and
holding the playhead fixed during a pinch is the whole point of the interaction.

## Scale

`TimelineScale` stores points per second, so both conversions are a multiply:

```swift
func point(for time: TimeInterval) -> CGFloat
func time(for point: CGFloat) -> TimeInterval
```

Snap tolerance is defined in *points* and converted to seconds, so snapping feels
identical at every zoom level. Ruler tick spacing is chosen from a fixed ladder
of intervals — the first one wide enough that labels cannot collide.

The timeline opens fitted to the media's duration.

## Zoom

Pinch scales `pointsPerSecond` around the playhead. Because the playhead is
fixed, nothing further is needed to preserve the focal point: the time under the
centre does not change, so the frame under it does not move. Haptics fire when
the scale reaches either limit.

## Tracks

Tracks appear only when there is something on them:

```
Video  ██████████████████████
Text       ━━━━━━━━━
Photo          ━━━━━━━
Audio  ━━━━━━━━━━━━━━━━━━━━━━
```

A plain video edit is one strip. The overlay row appears with the first text,
image, drawing or blur; the audio row with the first audio clip. This is the same
principle as the contextual toolbar: nothing is shown until it applies to
something.

## Thumbnails

`ThumbnailProvider` is an actor. Three rules keep it cheap enough to run during a
pinch:

- **Batched.** One `AVAssetImageGenerator.images(for:)` sequence per clip, not
  one request per frame.
- **Cached** by asset, height and source time rounded to a quarter second, which
  is finer than a filmstrip needs and coarse enough to hit while scrubbing.
- **Cancellable.** A new request for a clip cancels the previous batch, so a zoom
  gesture does not leave twenty superseded decodes running.

Generators are configured with a 0.35 s tolerance in both directions. A filmstrip
does not need frame accuracy, and letting the generator land on the nearest
keyframe is the difference between smooth zooming and a stutter.

## Waveforms

`AudioWaveformGenerator` streams the file through `AVAssetReader` block by block
rather than loading it, so a ten-minute track costs the same memory as a
ten-second one. Amplitudes are rectified with `vDSP_vabs` and reduced to per-bucket
peaks with `vDSP_maxv`; peaks read better than an RMS envelope at timeline sizes.
Results are cached per asset and normalised so a quiet recording still fills its
strip.

## Range selection

`RangeSelectionOverlay` draws the band Remove Range will delete, with a handle at
each end and a live duration readout. Dragging a handle updates
`EditorSession.pendingRemovalRange`; the operation itself only runs on confirm.

## Snapping

`EditDocument.snapPoints` collects clip edges, keyframe times, audio clip edges
and overlay boundaries. Scrubbing snaps to the nearest one within tolerance and
fires a single haptic on entering it — not on every frame while inside it.
