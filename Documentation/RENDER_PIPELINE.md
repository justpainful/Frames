# Render pipeline

## One composer

`FrameComposer.compose` turns a source frame plus an `EditDocument` into the
finished picture. It is synchronous and pure, so the same function runs:

- on the main actor for a still preview,
- inside an `AVVideoCompositing` callback for video preview,
- inside the same compositor at `RenderQuality.final` for export.

There is no second implementation of any visible effect. That is the mechanism
behind "what you see is what you get" — not a policy, a fact about the call
graph.

## Stage order

```
source frame
 1. geometry        crop, straighten, flip
 2. portrait        low-light denoise, edge-aware smoothing, detail restore
 3. grade           filter recipe, then the user's adjustments
 4. selective       masked adjustments
 5. effects         texture and motion
 6. blur            masked blur, last of the pixel stages
 7. fit             place in the output frame, fill the rest
 8. overlays        text, images, drawings
```

Each position is load-bearing:

- **Geometry first** so a vignette hugs the cropped edges rather than the
  original ones.
- **Portrait before the grade**, because noise has to be dealt with before the
  shadows are lifted — lifting first amplifies exactly what needs removing.
- **Filter before adjustments**, because the filter is the base look and the
  user's own sliders sit on top of it, which is the order people expect after
  they pick a filter and then nudge exposure.
- **Blur last of the pixel stages**, so blurring a face actually hides it instead
  of hiding a version of it that a later sharpen brings back.
- **Overlays on top of everything**, unblurred and ungraded, because they are the
  user's annotations rather than part of the photograph.

## Contexts

`RenderContext` creates exactly two `CIContext`s for the life of the app: one for
preview and one for export. Creating a `CIContext` allocates a Metal command
queue and a texture cache, and creating one per operation is the most common way
to make a Core Image pipeline slow.

Both work in extended linear sRGB so highlights survive the chain. The export
context additionally asks for high-quality downsampling.

## Quality

`RenderQuality` has three levels. `.interactive` skips the most expensive stages
and halves blur radii through `samplingScale`, so dragging a slider stays at
display rate. `.preview` and `.final` produce identical results — the only
difference between what is on screen and what is written is resolution.

## Filters as recipes

A `FilterPreset` is a `FilterRecipe`: an adjustment set, per-channel gain and
lift, a tone curve, split toning, a monochrome flag and a bloom amount. It is not
a lookup table.

Two consequences. Intensity is a real interpolation of the recipe's parameters
towards identity, not a cross-fade between two rendered images, so a filter at
40% composes correctly with the user's own adjustments. And improving a filter
improves every existing session, because only the identifier and intensity are
persisted.

Split toning is one `CIColorPolynomial` pass: the shadow term `s·(1−c)²` expands
to `s − 2s·c + s·c²` and the highlight term is `h·c²`, so both fall off exactly
where they should with no mask and no second render.

## Video composition

`CompositionEngine` builds an `AVMutableComposition` carrying *structure only* —
which piece of which file plays when. Two video tracks alternate so a transition
can overlap two clips. Speed and freeze are `scaleTimeRange`. Audio fades,
volume keyframes and auto-ducking become `AVMutableAudioMixInputParameters`
ramps, which means ducking is editable and reversible rather than baked into the
audio.

`FramesVideoCompositor` is a custom `AVVideoCompositing` rather than
`applyingCIFiltersWithHandler`, for two reasons: transitions need two source
frames at once, and clips shot in different orientations need their preferred
transforms applied individually.

Because the compositor cannot await, everything asynchronous is resolved into a
`VideoRenderPlan` before playback starts: overlay images, cut-outs, rasterised
drawings, and the analyzer that Vision work goes through.

## Rebuild boundaries

Changing a filter must not rebuild the player graph. `CompositionEngine.structureSignature`
hashes only what AVFoundation needs to know — clips, audio, aspect, assets — and
`PlaybackEngine.load(…, signature:)` no-ops when it has not changed. Colour, blur
and overlays travel to the compositor and never touch the player item.

## Export

`ExportService` builds the same composition at `.final` and, if the chosen
resolution differs, rebuilds once at the export's own output size so the
compositor renders straight to the final resolution instead of scaling
afterwards. Progress comes from `AVAssetExportSession.states(updateInterval:)`
running alongside the write.

Stills go through `ImageRenderEngine.export`, which is the preview call with a
full-resolution decode and a `.final` quality.
