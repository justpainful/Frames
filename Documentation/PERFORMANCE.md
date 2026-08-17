# Performance

Frames is a photo and video editor on a phone. Almost every performance rule here
exists because the naive version of the same code makes the interface stutter or
the app get killed.

## Never decode on the main actor

- `ImageLoader` is an actor. Every still goes through
  `CGImageSourceCreateThumbnailAtIndex` with a pixel budget, so editing a
  48-megapixel photo does not decode 48 megapixels to show it on a six-inch
  screen. Full resolution is decoded exactly once, at export.
- `ThumbnailProvider` and `AudioWaveformGenerator` are actors.
- `VideoFrameSampler` uses the async `AVAssetImageGenerator.image(at:)`.

## Cancel superseded work

Anything the user can outrun is cancellable and gets cancelled:

- Thumbnail batches are cancelled when a clip's request supersedes them.
- The still preview render is debounced 40 ms and the previous task cancelled, so
  a slider drag produces one render per settled value rather than one per frame.
- Autosave is debounced 600 ms. A drag produces dozens of document mutations a
  second and none of them is worth a disk write on its own.
- Tracking runs in a `Task` the user can stop, and checks `Task.isCancelled`
  every step.

## Do not rebuild what did not change

The most important rule in the app. `CompositionEngine.structureSignature` hashes
only what AVFoundation needs to know: clips, audio, aspect, assets. Changing a
filter, a blur or an overlay does not change it, so `PlaybackEngine.load` no-ops
and the player keeps its decoders, its buffer and its playback position.
`updateVideoComposition` swaps the filter chain on the item that is already
playing.

`PlaybackEngine` also holds one `AVPlayer` for the life of the editor and exposes
it as a stable object, so a SwiftUI body re-evaluation can never rebuild the
player graph. `PlayerLayerView.updateUIView` compares before assigning for the
same reason.

## Reuse contexts

`RenderContext` creates two `CIContext`s, once. Each one owns a Metal command
queue and a texture cache; creating one per operation is the single most common
way to make a Core Image pipeline slow.

`GrainRenderer` keeps one infinite noise image rather than generating noise per
frame, and offsets it per frame so video grain stays alive.

## Cache derived work

| Cache | Key | Bound |
|---|---|---|
| Decoded stills | path, max pixel size, modification date | 12 entries |
| Timeline thumbnails | asset, quarter second, height | 320 entries |
| Waveforms | file name, bucket count | per session |
| Vision detections | quantised frame identity + requirements | 24 entries |
| Overlay images and cut-outs | asset id, overlay id | per session |
| Still preview | visual signature + pixel budget | 1 |

Every one is bounded. An unbounded cache in a media app is a memory warning with
a delay on it.

## Do not hold frames

Nothing keeps a sequence of decoded frames. Export streams through
`AVAssetExportSession`; the compositor renders one frame into one pixel buffer
from the render context's pool and hands it straight back. `startRequest` wraps
its work in an `autoreleasepool` because it runs thousands of times in a row and
Core Image allocates freely inside each one.

## Interactive quality

`RenderQuality.interactive` halves blur and mask radii through `samplingScale`
and skips stages whose cost is not worth a mid-gesture frame — grain, bloom, the
second Portrait denoise pass, final local contrast. `.preview` and `.final` are
identical, so nothing the user settles on is ever approximate.

## Vision budgets

Analysis images are downsampled to 1024 px interactively and 768 px in the
compositor. `FrameAnalyzer` reuses a detection for a sixth of a second of
composition time; running segmentation on every frame of a 60 fps export would
dominate the render.

## Disk

`SessionPaths` puts recoverable state in Application Support (excluded from
backup), derived data in Caches, and renders in the temporary directory. Scratch
is emptied at launch and after every export; caches older than a week are pruned.
The export checks free space before starting, because running out halfway through
a 4K render wastes minutes.

## Instruments

Every expensive operation is bracketed with an `OSSignposter` interval:
`import`, `composeFrame`, `renderPhotoPreview`, `exportPhoto`, `export`,
`buildComposition`, `thumbnails`, `waveform`, `detectFaces`, `personMasks`,
`subjectMask`, `frameAnalysis`. They show up as intervals in Instruments rather
than as a wall of point events, so a slow frame can be attributed rather than
guessed at.
