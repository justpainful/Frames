import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Portrait mode: the whole pipeline, in one place.
///
/// The problem this solves is not "smooth the skin". Indoor footage arrives with
/// four things going wrong at once — sensor noise, the camera's own sharpening
/// exaggerating pores, shadows with no colour left in them, and an exposure that
/// cannot be raised without raising the noise with it. Fixing any one of them in
/// isolation makes another worse, which is why this is a single ordered chain
/// rather than a set of independent effects:
///
/// 1. **Chroma denoise** — colour noise first, before anything reads colour.
/// 2. **Luma denoise** — grain, before the shadow lift amplifies it.
/// 3. **Exposure and shadow recovery** — lift, then restore contrast and
///    saturation so the rescued frame does not go flat and grey.
/// 4. **Edge map** — a difference of two gaussians, wide enough that pores and
///    grain cancel out of it and only structure survives.
/// 5. **Edge-aware smoothing** — strong where the edge response is low, which is
///    the uniform skin between features; collapsing to nothing at structure.
/// 6. **Detail restoration** — the high-frequency layer put back through the
///    same edge map, so features return and pore-scale texture does not.
/// 7. **Evenness** — a very wide low-pass applied to colour only, so blotchy
///    skin tone flattens while every luminance gradient survives.
/// 8. **Warmth** — puts back the tone denoise takes out of skin.
/// 9. **Glow** — a highlight-tied bloom, screened back.
/// 10. **Clarity** — local contrast at a large radius, which reads as crisp
///     without bringing a single pore with it.
///
/// Nothing here moves a pixel. There is no warp, no liquify, no reshaping: every
/// stage changes how existing light and texture *read*, and the geometry of the
/// person is exactly the geometry the camera recorded.
enum PortraitProcessor {

    // MARK: - Resolved amounts

    /// What the settings actually mean for this frame, once the measured
    /// brightness has been taken into account.
    ///
    /// These are separated from the settings so they can be smoothed between
    /// frames as plain numbers. Every field is normalized to 0...1 and mapped
    /// onto filter inputs at the point of use.
    struct Amounts: Hashable, Sendable {
        var lumaNoise: Double
        var chromaBlur: Double
        var exposureLift: Double
        var shadowLift: Double
        var contrastRestore: Double
        var smoothing: Double
        var detail: Double
        var evenness: Double
        var warmth: Double
        var glow: Double

        /// Moves every amount a fraction of the way from the previous frame's
        /// value towards this frame's. This is the entire anti-flicker
        /// mechanism: exposure cannot pump, smoothing cannot pulse, and glow
        /// cannot breathe, because none of them can change faster than the
        /// stability setting allows.
        func smoothed(towards previous: Amounts?, stability: Double) -> Amounts {
            guard let previous else { return self }
            var result = self
            result.lumaNoise = PortraitProcessor.temporallySmoothed(
                lumaNoise, previous: previous.lumaNoise, stability: stability)
            result.chromaBlur = PortraitProcessor.temporallySmoothed(
                chromaBlur, previous: previous.chromaBlur, stability: stability)
            result.exposureLift = PortraitProcessor.temporallySmoothed(
                exposureLift, previous: previous.exposureLift, stability: stability)
            result.shadowLift = PortraitProcessor.temporallySmoothed(
                shadowLift, previous: previous.shadowLift, stability: stability)
            result.contrastRestore = PortraitProcessor.temporallySmoothed(
                contrastRestore, previous: previous.contrastRestore, stability: stability)
            result.smoothing = PortraitProcessor.temporallySmoothed(
                smoothing, previous: previous.smoothing, stability: stability)
            result.detail = PortraitProcessor.temporallySmoothed(
                detail, previous: previous.detail, stability: stability)
            result.evenness = PortraitProcessor.temporallySmoothed(
                evenness, previous: previous.evenness, stability: stability)
            result.warmth = PortraitProcessor.temporallySmoothed(
                warmth, previous: previous.warmth, stability: stability)
            result.glow = PortraitProcessor.temporallySmoothed(
                glow, previous: previous.glow, stability: stability)
            return result
        }
    }

    /// Maps the settings and the frame's measured average luminance onto the
    /// amounts each stage runs at.
    ///
    /// Low light is not a separate mode, it is this function: the darker the
    /// measurement, the more of the low-light budget is spent, and at a normally
    /// exposed frame the recovery stages contribute nothing at all no matter
    /// where the slider sits.
    ///
    /// - Parameter isWholeFrameFallback: true when the user asked for people
    ///   only but no mask was available. The frame is still processed — doing
    ///   nothing would be worse — but a little more gently, because the
    ///   background is now being smoothed too.
    static func resolveAmounts(
        for settings: PortraitSettings,
        luminance: Double,
        isWholeFrameFallback: Bool
    ) -> Amounts {
        let level = clamp01(luminance)
        // Darkness rises as the average drops below a normally exposed mid
        // grey. At 0.5 and above it is zero, so a well-lit frame never gets a
        // shadow lift it did not need.
        let darkness = clamp01((0.5 - level) / 0.5)

        let requestedSmoothing = clamp01(settings.smoothing)
        let requestedEvenness = clamp01(settings.evenness)
        let lowLight = clamp01(settings.lowLight)
        let fallbackScale = isWholeFrameFallback ? 0.82 : 1.0

        let exposureLift = clamp01(lowLight * darkness)
        let shadowLift = clamp01(lowLight * (0.28 + 0.72 * darkness))

        return Amounts(
            // Denoise strength follows the darkness, because that is where the
            // noise is, plus a floor tied to smoothing: asking for very smooth
            // skin implies cleaning the grain that would otherwise survive it.
            lumaNoise: clamp01(lowLight * (0.35 + 0.65 * darkness) + requestedSmoothing * 0.22),
            chromaBlur: clamp01(clamp01(settings.colorNoiseReduction) * (0.45 + 0.55 * darkness)),
            exposureLift: exposureLift,
            shadowLift: shadowLift,
            // Whatever was lifted has to be paid back as contrast, or the frame
            // reads washed out rather than rescued.
            contrastRestore: clamp01(shadowLift * 0.7 + exposureLift * 0.3),
            smoothing: clamp01(requestedSmoothing * fallbackScale),
            detail: clamp01(settings.detailPreservation),
            evenness: clamp01(requestedEvenness * fallbackScale),
            // Denoising pulls warmth out of shadows first, so a darker frame
            // needs more of the warmth budget to land in the same place.
            warmth: clamp01(clamp01(settings.warmth) * (0.65 + 0.35 * darkness)),
            glow: clamp01(settings.glow)
        )
    }

    /// One step of exponential smoothing towards the previous frame's value.
    ///
    /// At stability 0 the current value is used outright; at 1 only a tenth of
    /// each change lands per frame, which is slow enough to erase flicker and
    /// still fast enough to follow someone walking into better light.
    static func temporallySmoothed(_ current: Double, previous: Double?, stability: Double) -> Double {
        guard let previous else { return current }
        let held = clamp01(stability)
        // Short-circuited rather than left to the arithmetic, so "no stability"
        // means the value is passed through exactly rather than through a
        // rounding error's worth of the previous one.
        guard held > 0 else { return current }
        return previous + (current - previous) * (1 - held * 0.9)
    }

    /// Whether the carried state describes a different part of the media.
    ///
    /// A seek, a loop back to the start or a jump forward means the next frame
    /// is not a continuation of the last one, and smoothing towards values
    /// measured somewhere else would drag the wrong exposure into it.
    static func shouldResetState(previousTime: TimeInterval?, time: TimeInterval) -> Bool {
        guard let previousTime else { return false }
        return time < previousTime || time - previousTime > 0.5
    }

    // MARK: - Entry point

    static func apply(
        _ settings: PortraitSettings,
        to image: CIImage,
        personMask: CIImage?,
        state: PortraitTemporalState?,
        time: TimeInterval,
        quality: RenderQuality
    ) -> CIImage {
        guard settings.isActive else { return image }
        let extent = image.extent
        guard extent.isRenderable else { return image }

        let signpost = FramesLog.signposter.beginInterval("portrait")
        defer { FramesLog.signposter.endInterval("portrait", signpost) }

        if let state, shouldResetState(previousTime: state.lastTime, time: time) {
            state.reset()
        }

        let usesMask = settings.restrictToPeople && personMask != nil
        let luminance = measuredLuminance(of: image, extent: extent, state: state, time: time)

        // No longer a whole-frame fallback. Without a person mask the cosmetic
        // stages are still confined by the colour-derived skin mask, so there
        // is nothing to hold back from — pulling the amounts down here would
        // just under-apply the treatment during capture, which is the one place
        // Vision cannot keep up and the colour mask is doing all the work.
        var amounts = resolveAmounts(
            for: settings,
            luminance: luminance,
            isWholeFrameFallback: false
        )
        amounts = amounts.smoothed(towards: state?.amounts, stability: settings.temporalStability)
        state?.amounts = amounts
        state?.advance(to: time)

        let shortEdge = min(extent.width, extent.height)
        let scale = quality.samplingScale

        // Stages 1 and 2. Noise goes first and unconditionally: everything after
        // this reads colour or lifts brightness, and both amplify whatever noise
        // is still present.
        var cleaned = chromaDenoised(
            image, amount: amounts.chromaBlur, shortEdge: shortEdge, scale: scale, extent: extent)
        cleaned = lumaDenoised(
            cleaned, amount: amounts.lumaNoise, smoothing: amounts.smoothing,
            quality: quality, extent: extent)

        // Stage 3. The whole frame gets this, mask or no mask: recovering a dark
        // room is a property of the shot, not of the person in it.
        let recovered = exposureRecovered(cleaned, amounts: amounts, extent: extent)

        let edges = edgeMap(of: recovered, shortEdge: shortEdge, scale: scale, extent: extent)

        // Stages 4 to 9 are cosmetic, and cosmetic work applied to the whole
        // frame is the reason processed video looks processed. Smoothing the
        // wall, the hair and the shirt alongside the face reads as a layer over
        // the picture no matter how good the smoothing is. Everything from here
        // is composited back through a mask of where skin actually is.
        var treated = surfaceSmoothed(
            recovered, edges: edges, amounts: amounts,
            shortEdge: shortEdge, scale: scale, extent: extent)
        treated = evened(
            treated, amount: amounts.evenness, shortEdge: shortEdge, scale: scale, extent: extent)
        treated = warmed(treated, amount: amounts.warmth, extent: extent)
        treated = glowed(
            treated, amount: amounts.glow, shortEdge: shortEdge, scale: scale, extent: extent)

        // A perfectly clean surface is the other half of the tell. Real skin
        // photographed by a real camera keeps a trace of fine noise, and a
        // surface with none of it reads as painted rather than photographed.
        // The floor goes on before the composite so it only ever lands where
        // the smoothing did.
        treated = textureFloor(
            treated, amount: amounts.smoothing, time: time, extent: extent)

        var output = treated
        if let skin = skinMask(
            of: recovered,
            edges: edges,
            personMask: usesMask ? personMask : nil,
            state: state,
            settings: settings,
            shortEdge: shortEdge,
            scale: scale,
            extent: extent
        ) {
            output = MaskRenderer.blend(effect: treated, over: recovered, using: skin, extent: extent)
        }

        // Clarity is photographic rather than cosmetic — it is what the lens
        // and the sensor would have given you — so it applies to the whole
        // frame, after the composite, and keeps the background crisp against
        // the smoothed skin.
        return clarified(
            output, amounts: amounts, shortEdge: shortEdge, scale: scale,
            quality: quality, extent: extent)
    }

    /// Where the cosmetic stages are allowed to land.
    ///
    /// Three tests, narrowing: the pixel has to be skin-coloured, it has to be
    /// in a flat area rather than on an edge, and — when Vision has supplied a
    /// person mask — it has to be on the person. The result is temporally
    /// smoothed for the same reason the amounts are: a mask that changes shape
    /// every frame is visible as a crawling outline even when each individual
    /// frame is right.
    private static func skinMask(
        of image: CIImage,
        edges: CIImage,
        personMask: CIImage?,
        state: PortraitTemporalState?,
        settings: PortraitSettings,
        shortEdge: CGFloat,
        scale: CGFloat,
        extent: CGRect
    ) -> CIImage? {
        guard var mask = SkinToneMask.mask(for: image, softness: Double(scale)) else { return nil }
        mask = SkinToneMask.restrictedToFlatAreas(mask, edges: edges, extent: extent)

        if let personMask {
            let stabilised = stabilisedMask(
                personMask, state: state, stability: settings.temporalStability,
                shortEdge: shortEdge, scale: scale, extent: extent)
            mask = SkinToneMask.intersected(mask, with: stabilised, extent: extent)
        }
        return mask
    }

    /// Puts a trace of fine grain back over the treated area.
    ///
    /// Deliberately small and monochrome. The goal is not a film look — it is
    /// that skin keeps the faint irregularity every real photograph has, so the
    /// eye reads the surface as a surface rather than as fill.
    private static func textureFloor(
        _ image: CIImage,
        amount: Double,
        time: TimeInterval,
        extent: CGRect
    ) -> CIImage {
        // Scales with how much was removed: light smoothing has left enough of
        // its own texture, heavy smoothing has left none.
        let floor = min(max(amount, 0), 1) * 0.055
        guard floor > 0.004 else { return image }
        return GrainRenderer.apply(amount: floor, to: image, seed: time * 24)
    }

    // MARK: - Measurement

    /// The frame's average luminance, reused between frames.
    ///
    /// Re-measuring costs a round trip to the GPU for a number that barely
    /// moves. Five times a second follows a real lighting change and keeps the
    /// measurement off the per-frame path.
    private static func measuredLuminance(
        of image: CIImage,
        extent: CGRect,
        state: PortraitTemporalState?,
        time: TimeInterval
    ) -> Double {
        if let state, let cached = state.luminance, let measured = state.luminanceTime,
           time - measured < 0.2 {
            return cached
        }
        guard let value = averageLuminance(of: image, extent: extent) else {
            // A neutral mid grey means the low-light stages contribute nothing,
            // which is the right answer when the frame cannot be measured.
            return state?.luminance ?? 0.5
        }
        state?.luminance = value
        state?.luminanceTime = time
        return value
    }

    private static func averageLuminance(of image: CIImage, extent: CGRect) -> Double? {
        guard extent.isRenderable else { return nil }

        // Reducing first keeps the reduction the GPU has to perform small; the
        // average of a 128-pixel version of a frame and the average of the frame
        // are the same number to far more precision than this needs.
        var source = image
        let longEdge = max(extent.width, extent.height)
        if longEdge > 128 {
            let factor = 128 / longEdge
            source = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        let region = source.extent
        guard region.isRenderable else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = source
        filter.extent = region
        guard let output = filter.outputImage else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        // Always the preview context, at every quality: the measurement feeds a
        // visible decision, so it has to produce the same number in the export
        // as it did on screen.
        RenderContext.shared.preview.render(
            output,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        let red = Double(bytes[0]) / 255
        let green = Double(bytes[1]) / 255
        let blue = Double(bytes[2]) / 255
        return clamp01(0.2126 * red + 0.7152 * green + 0.0722 * blue)
    }

    // MARK: - Stage 1: chroma denoise

    private static func chromaDenoised(
        _ image: CIImage,
        amount: Double,
        shortEdge: CGFloat,
        scale: Double,
        extent: CGRect
    ) -> CIImage {
        guard amount > 0.001 else { return image }

        let radius = Double(shortEdge) * 0.004 * amount * scale
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(max(radius, 0.6))
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return image }

        // Colour noise lives in the colour channels and almost nowhere else, so
        // the fix is to blur colour and leave luminance completely alone.
        // CILuminosityBlendMode keeps the luminance of the input image and the
        // hue and saturation of the background, so the original goes in as the
        // input and the blurred copy as the background: the blotches in dark
        // areas go, and not one edge or highlight has moved.
        let combine = CIFilter.luminosityBlendMode()
        combine.inputImage = image
        combine.backgroundImage = blurred
        return combine.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Stage 2: luma denoise

    private static func lumaDenoised(
        _ image: CIImage,
        amount: Double,
        smoothing: Double,
        quality: RenderQuality,
        extent: CGRect
    ) -> CIImage {
        guard amount > 0.001 else { return image }

        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        filter.noiseLevel = Float(0.008 + amount * 0.045)
        // Core Image's own edge sharpening is turned down as smoothing rises;
        // leaving it up is what makes a denoised frame look crunchy.
        filter.sharpness = Float(max(0, 0.4 - smoothing * 0.3))
        var output = filter.outputImage?.cropped(to: extent) ?? image

        if quality.appliesExpensiveStages, amount > 0.5 {
            // Deep shadow keeps some grain through one pass. A second, gentler
            // pass finishes it, and is the first thing dropped mid-gesture
            // because it is the least visible stage in the chain.
            let second = CIFilter.noiseReduction()
            second.inputImage = output
            second.noiseLevel = Float(0.008 + amount * 0.018)
            second.sharpness = 0
            output = second.outputImage?.cropped(to: extent) ?? output
        }
        return output
    }

    // MARK: - Stage 3: exposure and shadow recovery

    private static func exposureRecovered(
        _ image: CIImage,
        amounts: Amounts,
        extent: CGRect
    ) -> CIImage {
        var output = image

        if amounts.shadowLift > 0.001 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = output
            filter.shadowAmount = Float(amounts.shadowLift * 0.65)
            // Pulling the highlights down slightly is what stops the brightest
            // skin from clipping once the rest of the frame comes up.
            filter.highlightAmount = Float(1 - amounts.shadowLift * 0.25)
            filter.radius = 14
            output = filter.outputImage?.cropped(to: extent) ?? output

            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            // The black point does not move. Only the quarter tone and, very
            // slightly, the midpoint do — which is the difference between
            // opening the shadows and washing them out to grey.
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: CGFloat(0.25 + amounts.shadowLift * 0.07))
            curve.point2 = CGPoint(x: 0.5, y: CGFloat(0.5 + amounts.shadowLift * 0.03))
            curve.point3 = CGPoint(x: 0.75, y: 0.75)
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage?.cropped(to: extent) ?? output
        }

        if amounts.exposureLift > 0.001 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            // A little over one stop at the extreme. More than that and the
            // noise wins regardless of what was done about it above.
            filter.ev = Float(amounts.exposureLift * 1.1)
            output = filter.outputImage?.cropped(to: extent) ?? output
        }

        if amounts.contrastRestore > 0.001 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = 0
            filter.contrast = Float(1 + amounts.contrastRestore * 0.14)
            // Denoising and a shadow lift both cost saturation. Putting a little
            // back is what keeps a rescued frame from reading grey.
            filter.saturation = Float(1 + amounts.contrastRestore * 0.08)
            output = filter.outputImage?.cropped(to: extent) ?? output
        }

        return output
    }

    // MARK: - Stage 4: edge map

    /// White where there is structure, black across uniform skin.
    ///
    /// Built as a difference of two gaussians rather than from a gradient
    /// filter, partly because it is guaranteed to exist and partly because it is
    /// the right measure here: both radii are far wider than a pore, so grain
    /// and micro-texture are identical in the two copies and cancel out of the
    /// subtraction. What survives is what has a real boundary — an eyelid, a
    /// lip, a finger, the edge of a sleeve, a clump of hair.
    private static func edgeMap(
        of image: CIImage,
        shortEdge: CGFloat,
        scale: Double,
        extent: CGRect
    ) -> CIImage? {
        let mono = CIFilter.colorControls()
        mono.inputImage = image
        mono.brightness = 0
        mono.contrast = 1
        mono.saturation = 0
        guard let gray = mono.outputImage?.cropped(to: extent) else { return nil }

        let inner = Float(max(Double(shortEdge) * 0.0035 * scale, 1))
        let outer = max(Float(Double(shortEdge) * 0.014 * scale), inner * 3)

        let fine = CIFilter.gaussianBlur()
        fine.inputImage = gray.clampedToExtent()
        fine.radius = inner

        let coarse = CIFilter.gaussianBlur()
        coarse.inputImage = gray.clampedToExtent()
        coarse.radius = outer

        guard let fineImage = fine.outputImage?.cropped(to: extent),
              let coarseImage = coarse.outputImage?.cropped(to: extent)
        else { return nil }

        // A difference blend gives the magnitude of the band, which is what a
        // weight needs: an edge counts the same whether it runs light-to-dark
        // or dark-to-light.
        let difference = CIFilter.differenceBlendMode()
        difference.inputImage = fineImage
        difference.backgroundImage = coarseImage
        guard let banded = difference.outputImage?.cropped(to: extent) else { return nil }

        // The band response is a few percent of full scale even at a strong
        // edge, so it has to be amplified and then bounded before it can be
        // used as a 0...1 weight.
        guard let amplified = scaled(banded, by: 12, extent: extent) else { return nil }

        let bounded = CIFilter.colorClamp()
        bounded.inputImage = amplified
        bounded.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        bounded.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let clamped = bounded.outputImage?.cropped(to: extent) else { return nil }

        // Spreading the weight covers the whole edge rather than a one-pixel
        // line. That is what stops a halo appearing beside structure, and it is
        // also what stops the weight itself from crawling between frames.
        let spread = CIFilter.gaussianBlur()
        spread.inputImage = clamped.clampedToExtent()
        spread.radius = max(inner * 1.5, 1)
        return spread.outputImage?.cropped(to: extent)
    }

    // MARK: - Stages 5 and 6: smoothing and detail restoration

    private static func surfaceSmoothed(
        _ image: CIImage,
        edges: CIImage?,
        amounts: Amounts,
        shortEdge: CGFloat,
        scale: Double,
        extent: CGRect
    ) -> CIImage {
        guard amounts.smoothing > 0.001 else { return image }

        // The heavily smoothed candidate, in two parts: an edge-preserving pass
        // that removes speckle and roughness, then a small gaussian that takes
        // out what is left at pore scale. The gaussian is deliberately tiny —
        // a few pixels on a 1080-line frame — because the smoothing that
        // matters comes from *where* this is applied, not from its radius.
        let flatten = CIFilter.noiseReduction()
        flatten.inputImage = image
        flatten.noiseLevel = Float(0.02 + amounts.smoothing * 0.055)
        flatten.sharpness = 0
        var smooth = flatten.outputImage?.cropped(to: extent) ?? image

        let radius = Double(shortEdge) * (0.0012 + amounts.smoothing * 0.0055) * scale
        let soften = CIFilter.gaussianBlur()
        soften.inputImage = smooth.clampedToExtent()
        soften.radius = Float(max(radius, 0.8))
        smooth = soften.outputImage?.cropped(to: extent) ?? smooth

        guard let edges else {
            // No edge map means no way to tell surface from structure, so the
            // safe thing is a gentle uniform mix rather than a strong one.
            return mix(smooth, over: image, amount: amounts.smoothing * 0.5, extent: extent)
        }

        // Protection: how strongly structure resists being smoothed. Detail
        // preservation widens it, so raising that slider does not merely add
        // detail back afterwards, it stops it being taken in the first place.
        guard let protection = scaled(edges, by: 0.5 + amounts.detail * 0.5, extent: extent),
              let openSkin = inverted(protection, extent: extent),
              let smoothWeight = scaled(openSkin, by: amounts.smoothing, extent: extent)
        else {
            return mix(smooth, over: image, amount: amounts.smoothing * 0.5, extent: extent)
        }
        var output = MaskRenderer.blend(effect: smooth, over: image, using: smoothWeight, extent: extent)

        // Detail restoration. `blendWithMask` computes
        //     base + weight * (effect - base)
        // so blending the unsmoothed picture back over the smoothed one through
        // the edge weight re-adds exactly the high-frequency layer smoothing
        // removed, scaled by that weight. The difference never has to exist as
        // an image of its own, which means there is no signed layer to encode
        // around a half-grey bias and nothing to clip on the way back.
        guard let detailWeight = scaled(edges, by: amounts.detail, extent: extent) else { return output }
        output = MaskRenderer.blend(effect: image, over: output, using: detailWeight, extent: extent)
        return output
    }

    // MARK: - Stage 7: evenness

    private static func evened(
        _ image: CIImage,
        amount: Double,
        shortEdge: CGFloat,
        scale: Double,
        extent: CGRect
    ) -> CIImage {
        guard amount > 0.001 else { return image }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(max(Double(shortEdge) * 0.05 * scale, 2))
        guard let wide = blur.outputImage?.cropped(to: extent) else { return image }

        // Colour only, again: the very wide blur supplies hue and saturation
        // while the picture keeps its own luminance. Patchiness in skin tone
        // flattens and every light and shadow gradient survives intact, which is
        // what stops evenness from turning into a wax finish.
        let combine = CIFilter.luminosityBlendMode()
        combine.inputImage = image
        combine.backgroundImage = wide
        guard let flattened = combine.outputImage?.cropped(to: extent) else { return image }
        return mix(flattened, over: image, amount: amount * 0.75, extent: extent)
    }

    // MARK: - Stage 8: warmth

    private static func warmed(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        guard amount > 0.001 else { return image }

        let temperature = CIFilter.temperatureAndTint()
        temperature.inputImage = image
        temperature.neutral = CIVector(x: 6500, y: 0)
        // A few hundred kelvin at most. This is not a look, it is putting back
        // what denoising took out of skin.
        temperature.targetNeutral = CIVector(x: CGFloat(6500 - amount * 620), y: CGFloat(amount * 6))
        var output = temperature.outputImage?.cropped(to: extent) ?? image

        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = output
        // Vibrance rather than saturation: it leaves already-saturated clothing
        // and background alone and acts mostly where skin sits.
        vibrance.amount = Float(amount * 0.2)
        output = vibrance.outputImage?.cropped(to: extent) ?? output
        return output
    }

    // MARK: - Stage 9: glow

    private static func glowed(
        _ image: CIImage,
        amount: Double,
        shortEdge: CGFloat,
        scale: Double,
        extent: CGRect
    ) -> CIImage {
        guard amount > 0.001 else { return image }

        let mono = CIFilter.colorControls()
        mono.inputImage = image
        mono.brightness = 0
        mono.contrast = 1
        mono.saturation = 0
        guard let gray = mono.outputImage?.cropped(to: extent) else { return image }

        // Cubing the luminance is what ties the glow to the highlights. A mid
        // tone contributes an eighth of what a highlight does, so the result is
        // a bloom around light rather than a haze over the frame.
        let shaped = CIFilter.colorPolynomial()
        shaped.inputImage = gray
        let cubic = CIVector(x: 0, y: 0, z: 0, w: 1)
        shaped.redCoefficients = cubic
        shaped.greenCoefficients = cubic
        shaped.blueCoefficients = cubic
        guard let highlightWeight = shaped.outputImage?.cropped(to: extent) else { return image }

        let black = CIImage(color: CIColor.black).cropped(to: extent)
        let highlights = MaskRenderer.blend(
            effect: image, over: black, using: highlightWeight, extent: extent)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = highlights.clampedToExtent()
        blur.radius = Float(max(Double(shortEdge) * 0.02 * scale, 2))
        guard let diffused = blur.outputImage?.cropped(to: extent),
              let level = scaled(diffused, by: amount * 0.5, extent: extent)
        else { return image }

        // Screen, so the glow can only add light. Where the highlight weight was
        // black nothing happens at all, which is why this cannot flatten the
        // frame's contrast the way a global haze would.
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = level
        screen.backgroundImage = image
        return screen.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Stage 10: clarity

    private static func clarified(
        _ image: CIImage,
        amounts: Amounts,
        shortEdge: CGFloat,
        scale: Double,
        quality: RenderQuality,
        extent: CGRect
    ) -> CIImage {
        guard quality.appliesExpensiveStages else { return image }

        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        // A large radius is local contrast, not sharpening. It puts back the
        // sense of depth and volume that smoothing costs, and because the radius
        // is two orders of magnitude wider than a pore it cannot bring one back.
        filter.radius = Float(min(max(Double(shortEdge) * 0.025 * scale, 8), 70))
        filter.intensity = Float(0.15 + amounts.detail * 0.25)
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Person mask

    /// The person mask, resampled, feathered and averaged with the previous
    /// frame's.
    ///
    /// Vision re-segments every frame and its boundary moves a pixel or two even
    /// when nothing has, which reads as a crawling outline around the person.
    /// Feathering hides the movement and averaging removes most of it.
    private static func stabilisedMask(
        _ mask: CIImage,
        state: PortraitTemporalState?,
        stability: Double,
        shortEdge: CGFloat,
        scale: Double,
        extent: CGRect
    ) -> CIImage {
        var resolved = resampled(mask, to: extent)

        let feather = CIFilter.gaussianBlur()
        feather.inputImage = resolved.clampedToExtent()
        feather.radius = Float(max(Double(shortEdge) * 0.006 * scale, 1.5))
        resolved = feather.outputImage?.cropped(to: extent) ?? resolved

        if let state {
            if let previous = state.personMask, previous.extent == extent {
                resolved = mix(previous, over: resolved, amount: clamp01(stability) * 0.45, extent: extent)
            }
            state.personMask = resolved
        }
        return resolved
    }

    private static func resampled(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let source = mask.extent
        guard source.isRenderable else { return mask }

        var output = mask
        let scaleX = extent.width / source.width
        let scaleY = extent.height / source.height
        if abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 {
            output = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        // Detection runs on the frame before it was placed, so the mask can come
        // back at the origin while the frame sits somewhere else after a crop.
        let placed = output.extent
        if placed.isRenderable {
            output = output.transformed(by: CGAffineTransform(
                translationX: extent.origin.x - placed.origin.x,
                y: extent.origin.y - placed.origin.y
            ))
        }
        return output.cropped(to: extent)
    }

    // MARK: - Helpers

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// Multiplies a weight image's colour channels, leaving alpha alone.
    private static func scaled(_ image: CIImage, by factor: Double, extent: CGRect) -> CIImage? {
        let gain = CGFloat(factor)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return filter.outputImage?.cropped(to: extent)
    }

    private static func inverted(_ image: CIImage, extent: CGRect) -> CIImage? {
        let filter = CIFilter.colorInvert()
        filter.inputImage = image
        return filter.outputImage?.cropped(to: extent)
    }

    /// Mixes one image over another by a constant amount, expressed as a flat
    /// mask so the composite goes through the same path as every masked stage.
    private static func mix(
        _ effect: CIImage,
        over base: CIImage,
        amount: Double,
        extent: CGRect
    ) -> CIImage {
        let value = clamp01(amount)
        guard value > 0.001 else { return base }
        guard value < 0.999 else { return effect }
        let level = CGFloat(value)
        let mask = CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: extent)
        return MaskRenderer.blend(effect: effect, over: base, using: mask, extent: extent)
    }
}
