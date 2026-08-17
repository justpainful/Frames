# Vision

Everything here runs on the device with Apple's Vision framework. No frame leaves
the phone, there is no model to download, and there is no network path in any of
it.

## What is detected

| Feature | Request | Used by |
|---|---|---|
| Faces | `VNDetectFaceRectanglesRequest` | Face blur, selective adjustment on a face |
| People, per person | `VNGeneratePersonInstanceMaskRequest` | Person blur |
| People, combined | `VNGeneratePersonSegmentationRequest` | Fallback when instances are unavailable |
| Foreground subject | `VNGenerateForegroundInstanceMaskRequest` | Background blur, Remove Background, Portrait |
| Arbitrary object | `VNTrackObjectRequest` | Tracked blur |

## Two entry points, on purpose

`VisionService` is an actor. Vision handlers are not safe to share across
concurrent calls, and serialising requests is also what stops a scrub from
queueing twenty simultaneous segmentations.

`FrameAnalyzer` is a plain class doing the same work synchronously, because
`AVVideoCompositing` cannot await. It is only ever touched from the compositor's
own queue.

## Cost control

Vision at full preview resolution is wasted work. Both paths downsample first:
1024 px on the long edge for interactive analysis, 768 px inside the compositor.
Face rectangles and segmentation masks are stable at those sizes, and the masks
are resampled to the frame extent afterwards.

`FrameAnalyzer` caches its result and reuses it for a sixth of a second of
composition time. Segmentation on every frame of a 60 fps export would dominate
the render, and a face does not move far in 160 ms.

`FrameResourceResolver` caches by a quantised frame identity, so scrubbing inside
one frame reuses the previous detection.

## Identity across frames

Vision does not give a still detection a stable identifier, but a blur has to
keep pointing at the same face for the whole clip. Frames stores the id the user
tapped and, on each later detection pass, matches each requested id to the
nearest detection to where that face was last seen. Detections nobody asked for
are also exposed under their own ids so a newly visible face is immediately
selectable.

## Tracking

Tracking is explicit and cached rather than continuous:

1. The user pauses and positions the region.
2. `beginTracking` seeds `VNSequenceRequestHandler` with that rectangle.
3. Frames steps forward four times a second, feeding each frame to
   `VNTrackObjectRequest`.
4. Samples are written into `document.trackedObjects`.

Because the samples live in the document, the preview and the export agree
exactly on where a tracked blur sits at any moment, reopening a session does not
re-run Vision, and undo works on a track like anything else.

Confidence below 0.25 stops the track and records `lostConfidenceAt`. The user is
told where it was lost and asked to reposition and continue, rather than the app
silently drawing a blur over the wrong part of the picture.

## Portrait

Portrait mode uses the foreground subject mask to keep its strongest processing
on people, and falls back to processing the whole frame at reduced strength when
no subject is found — doing nothing would be worse than doing less. The mask is
feathered and temporally averaged before use, because an unsteady mask edge is
visible as a crawling outline even when every individual frame looks correct.

## Failure

Detection failing is normal, not exceptional: there may be no face in the frame.
Every call site treats a missing result as "skip this stage", never as "blur the
whole picture". Where the user explicitly asked for something that could not be
found — Remove Background on an image with no subject — they get
`FramesError.visionUnavailable` with a message suggesting the manual route.
