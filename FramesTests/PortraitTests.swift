import Foundation
import Testing
@testable import Frames

@Suite("Portrait settings")
struct PortraitSettingsTests {

    @Test("The default settings are off and inactive")
    func offIsInactive() {
        #expect(PortraitSettings.off.isActive == false)
        #expect(PortraitSettings.off.isEnabled == false)
        #expect(PortraitSettings.off.needsPersonMask == false)
        #expect(PortraitSettings.off.matchingPreset == nil)
    }

    @Test("Every amount is clamped to 0...1")
    func amountsAreClamped() {
        let high = PortraitSettings(
            smoothing: 5, detailPreservation: 5, lowLight: 5, colorNoiseReduction: 5,
            glow: 5, evenness: 5, warmth: 5, temporalStability: 5
        )
        #expect(high.smoothing == 1)
        #expect(high.detailPreservation == 1)
        #expect(high.lowLight == 1)
        #expect(high.colorNoiseReduction == 1)
        #expect(high.glow == 1)
        #expect(high.evenness == 1)
        #expect(high.warmth == 1)
        #expect(high.temporalStability == 1)

        let low = PortraitSettings(
            smoothing: -5, detailPreservation: -5, lowLight: -5, colorNoiseReduction: -5,
            glow: -5, evenness: -5, warmth: -5, temporalStability: -5
        )
        #expect(low.smoothing == 0)
        #expect(low.detailPreservation == 0)
        #expect(low.lowLight == 0)
        #expect(low.colorNoiseReduction == 0)
        #expect(low.glow == 0)
        #expect(low.evenness == 0)
        #expect(low.warmth == 0)
        #expect(low.temporalStability == 0)
    }

    @Test("Every preset recognises itself")
    func presetsRoundTrip() {
        for preset in PortraitSettings.Preset.allCases {
            #expect(preset.settings.matchingPreset == preset, "\(preset.rawValue) did not match itself")
            #expect(preset.settings.isEnabled, "\(preset.rawValue) should turn Portrait on")
        }
    }

    @Test("Presets are distinct from one another")
    func presetsAreDistinct() {
        let all = PortraitSettings.Preset.allCases.map(\.settings)
        #expect(Set(all).count == all.count)
    }

    @Test("Moving a slider leaves no matching preset")
    func editingClearsTheMatch() {
        var settings = PortraitSettings.Preset.clean.settings
        settings.smoothing = min(settings.smoothing + 0.1, 1)
        #expect(settings.matchingPreset == nil)
    }

    @Test("A person mask is only needed when Portrait is on and restricted")
    func personMaskRequirement() {
        var settings = PortraitSettings.Preset.studio.settings
        #expect(settings.restrictToPeople)
        #expect(settings.needsPersonMask)

        settings.restrictToPeople = false
        #expect(settings.needsPersonMask == false)

        settings.restrictToPeople = true
        settings.isEnabled = false
        #expect(settings.needsPersonMask == false)
        #expect(settings.isActive == false)
    }

    @Test("Settings survive a coding round trip")
    func codingRoundTrip() throws {
        for preset in PortraitSettings.Preset.allCases {
            let data = try FramesJSON.encoder.encode(preset.settings)
            let decoded = try FramesJSON.decoder.decode(PortraitSettings.self, from: data)
            #expect(decoded == preset.settings)
            #expect(decoded.matchingPreset == preset)
        }

        let data = try FramesJSON.encoder.encode(PortraitSettings.off)
        #expect(try FramesJSON.decoder.decode(PortraitSettings.self, from: data) == .off)
    }

    @Test("Every preset is named and described")
    func presetMetadata() {
        for preset in PortraitSettings.Preset.allCases {
            #expect(!preset.displayName.isEmpty)
            #expect(!preset.detail.isEmpty)
            #expect(preset.id == preset.rawValue)
        }
    }
}

@Suite("Portrait temporal stability")
struct PortraitTemporalTests {

    @Test("Without a previous value the current one is used")
    func firstFrameIsUsedOutright() {
        #expect(PortraitProcessor.temporallySmoothed(0.8, previous: nil, stability: 1) == 0.8)
        #expect(PortraitProcessor.temporallySmoothed(0.2, previous: nil, stability: 0) == 0.2)
    }

    @Test("No stability means no holding")
    func zeroStabilityFollowsExactly() {
        #expect(PortraitProcessor.temporallySmoothed(0.9, previous: 0.1, stability: 0) == 0.9)
    }

    @Test("Full stability holds most of the previous value")
    func fullStabilityHolds() {
        let result = PortraitProcessor.temporallySmoothed(1, previous: 0, stability: 1)
        #expect(abs(result - 0.1) < 0.0001)
    }

    @Test("The result always lies between the two values")
    func resultStaysBetween() {
        for step in 0...10 {
            let stability = Double(step) / 10
            let rising = PortraitProcessor.temporallySmoothed(0.9, previous: 0.3, stability: stability)
            #expect(rising >= 0.3 && rising <= 0.9)

            let falling = PortraitProcessor.temporallySmoothed(0.3, previous: 0.9, stability: stability)
            #expect(falling >= 0.3 && falling <= 0.9)
        }
    }

    @Test("More stability moves less")
    func stabilityIsMonotone() {
        var previousResult = Double.infinity
        for step in 0...10 {
            let stability = Double(step) / 10
            let result = PortraitProcessor.temporallySmoothed(1, previous: 0, stability: stability)
            #expect(result <= previousResult + 0.0001, "stability \(stability) moved further than a lower one")
            previousResult = result
        }
    }

    @Test("Stability outside 0...1 behaves as if clamped")
    func stabilityIsClamped() {
        #expect(
            PortraitProcessor.temporallySmoothed(1, previous: 0, stability: 5)
                == PortraitProcessor.temporallySmoothed(1, previous: 0, stability: 1)
        )
        #expect(
            PortraitProcessor.temporallySmoothed(1, previous: 0, stability: -5)
                == PortraitProcessor.temporallySmoothed(1, previous: 0, stability: 0)
        )
    }

    @Test("State resets on a seek, not on ordinary playback")
    func stateResets() {
        #expect(PortraitProcessor.shouldResetState(previousTime: nil, time: 4) == false)
        #expect(PortraitProcessor.shouldResetState(previousTime: 4, time: 4 + 1.0 / 30) == false)
        #expect(PortraitProcessor.shouldResetState(previousTime: 4, time: 4.4) == false)
        #expect(PortraitProcessor.shouldResetState(previousTime: 4, time: 9) == true, "a forward seek")
        #expect(PortraitProcessor.shouldResetState(previousTime: 4, time: 1) == true, "a backward seek")
        #expect(PortraitProcessor.shouldResetState(previousTime: 4, time: 3.99) == true, "a loop back")
    }

    @Test("Smoothing a whole set of amounts holds every field")
    func amountsSmoothTogether() {
        let previous = PortraitProcessor.resolveAmounts(
            for: PortraitSettings.Preset.natural.settings, luminance: 0.5)
        let current = PortraitProcessor.resolveAmounts(
            for: PortraitSettings.Preset.lowLight.settings, luminance: 0.1)

        #expect(current.smoothed(towards: nil, stability: 1) == current)

        let held = current.smoothed(towards: previous, stability: 1)
        #expect(held.exposureLift < current.exposureLift)
        #expect(held.exposureLift > previous.exposureLift)
        #expect(held.smoothing < current.smoothing)

        let free = current.smoothed(towards: previous, stability: 0)
        #expect(free == current)
    }

    @Test("A fresh state holds nothing")
    func freshState() {
        let state = PortraitTemporalState()
        #expect(state.lastTime == nil)
        #expect(state.amounts == nil)
        #expect(state.luminance == nil)

        state.advance(to: 3)
        state.luminance = 0.4
        #expect(state.lastTime == 3)

        state.reset()
        #expect(state.lastTime == nil)
        #expect(state.luminance == nil)
    }
}

@Suite("Portrait resolved amounts")
struct PortraitAmountsTests {

    private static let luminances: [Double] = [0, 0.05, 0.2, 0.35, 0.5, 0.75, 1]

    private static let cases: [PortraitSettings] = PortraitSettings.Preset.allCases.map(\.settings) + [
        PortraitSettings(isEnabled: true),
        PortraitSettings(
            isEnabled: true, smoothing: 1, detailPreservation: 1, lowLight: 1,
            colorNoiseReduction: 1, glow: 1, evenness: 1, warmth: 1, temporalStability: 1
        ),
        PortraitSettings(
            isEnabled: true, smoothing: 0, detailPreservation: 0, lowLight: 0,
            colorNoiseReduction: 0, glow: 0, evenness: 0, warmth: 0, temporalStability: 0
        )
    ]

    @Test("Every resolved amount stays inside 0...1")
    func amountsStayInRange() {
        for settings in Self.cases {
            for luminance in Self.luminances {
                let amounts = PortraitProcessor.resolveAmounts(
                    for: settings, luminance: luminance)
                for value in [
                    amounts.lumaNoise, amounts.chromaBlur, amounts.exposureLift,
                    amounts.shadowLift, amounts.contrastRestore, amounts.smoothing,
                    amounts.detail, amounts.evenness, amounts.warmth, amounts.glow
                ] {
                    #expect(value >= 0 && value <= 1, "\(value) escaped the range")
                }
            }
        }
    }

    @Test("A darker frame gets more recovery")
    func darknessDrivesRecovery() {
        let settings = PortraitSettings(isEnabled: true, lowLight: 0.8)
        var previousExposure = -1.0
        var previousShadow = -1.0
        // Walking from bright to dark, neither recovery amount may ever fall.
        for luminance in Self.luminances.reversed() {
            let amounts = PortraitProcessor.resolveAmounts(
                for: settings, luminance: luminance)
            #expect(amounts.exposureLift >= previousExposure - 0.0001)
            #expect(amounts.shadowLift >= previousShadow - 0.0001)
            previousExposure = amounts.exposureLift
            previousShadow = amounts.shadowLift
        }
    }

    @Test("A normally exposed frame is not lifted at all")
    func brightFrameIsNotLifted() {
        let settings = PortraitSettings(isEnabled: true, lowLight: 1)
        let amounts = PortraitProcessor.resolveAmounts(
            for: settings, luminance: 0.7)
        #expect(amounts.exposureLift == 0)
        #expect(amounts.shadowLift > 0, "a shadow lift is still available, an exposure lift is not")
        #expect(amounts.shadowLift < 0.4)
    }

    @Test("Raising low light raises every low-light amount")
    func lowLightIsMonotone() {
        var previous = PortraitProcessor.resolveAmounts(
            for: PortraitSettings(isEnabled: true, lowLight: 0), luminance: 0.15)
        for step in 1...10 {
            let settings = PortraitSettings(isEnabled: true, lowLight: Double(step) / 10)
            let amounts = PortraitProcessor.resolveAmounts(
                for: settings, luminance: 0.15)
            #expect(amounts.exposureLift >= previous.exposureLift - 0.0001)
            #expect(amounts.shadowLift >= previous.shadowLift - 0.0001)
            #expect(amounts.lumaNoise >= previous.lumaNoise - 0.0001)
            #expect(amounts.contrastRestore >= previous.contrastRestore - 0.0001)
            previous = amounts
        }
    }

    @Test("Raising colour noise reduction raises the chroma amount")
    func colorNoiseIsMonotone() {
        var previous = 0.0
        for step in 0...10 {
            let settings = PortraitSettings(isEnabled: true, colorNoiseReduction: Double(step) / 10)
            let amounts = PortraitProcessor.resolveAmounts(
                for: settings, luminance: 0.3)
            #expect(amounts.chromaBlur >= previous - 0.0001)
            previous = amounts.chromaBlur
        }
    }

    @Test("Raising smoothing raises the smoothing amount")
    func smoothingIsMonotone() {
        var previous = 0.0
        for step in 0...10 {
            let settings = PortraitSettings(isEnabled: true, smoothing: Double(step) / 10)
            let amounts = PortraitProcessor.resolveAmounts(
                for: settings, luminance: 0.5)
            #expect(amounts.smoothing >= previous - 0.0001)
            previous = amounts.smoothing
        }
    }

    @Test("Luminance outside 0...1 behaves as if clamped")
    func luminanceIsClamped() {
        let settings = PortraitSettings.Preset.lowLight.settings
        #expect(
            PortraitProcessor.resolveAmounts(for: settings, luminance: -4)
                == PortraitProcessor.resolveAmounts(for: settings, luminance: 0)
        )
        #expect(
            PortraitProcessor.resolveAmounts(for: settings, luminance: 4)
                == PortraitProcessor.resolveAmounts(for: settings, luminance: 1)
        )
    }

    /// The presets exist to be visibly different from each other. A "Studio"
    /// that resolves to nearly the same numbers as "Natural" is four buttons
    /// doing one thing, which is how the previous version ended up feeling like
    /// it did nothing at all.
    @Test("The presets are meaningfully far apart")
    func presetsAreDistinctInEffect() {
        let natural = PortraitProcessor.resolveAmounts(
            for: PortraitSettings.Preset.natural.settings, luminance: 0.35)
        let studio = PortraitProcessor.resolveAmounts(
            for: PortraitSettings.Preset.studio.settings, luminance: 0.35)

        #expect(studio.smoothing > natural.smoothing + 0.2)
        #expect(studio.detail < natural.detail)
    }

    /// The colour stages were the only visible thing the earlier version did,
    /// and they are what made it read as a filter rather than a camera. They
    /// stay available as sliders and contribute nothing unless asked for.
    @Test("No preset applies a colour cast by default")
    func presetsDoNotTintByDefault() {
        for preset in PortraitSettings.Preset.allCases {
            let amounts = PortraitProcessor.resolveAmounts(
                for: preset.settings, luminance: 0.4)
            #expect(amounts.warmth == 0, "\(preset.rawValue) warms the picture")
            #expect(amounts.glow == 0, "\(preset.rawValue) glows")
            #expect(amounts.evenness == 0, "\(preset.rawValue) flattens colour")
        }
    }

    @Test("Every preset actually smooths")
    func presetsSmooth() {
        for preset in PortraitSettings.Preset.allCases {
            let amounts = PortraitProcessor.resolveAmounts(
                for: preset.settings, luminance: 0.4)
            #expect(amounts.smoothing >= 0.6, "\(preset.rawValue) barely smooths")
            #expect(preset.settings.hairRemoval > 0, "\(preset.rawValue) leaves stray hairs")
        }
    }

    @Test("Everything off resolves to nothing to do")
    func nothingRequestedIsNothingDone() {
        let settings = PortraitSettings(
            isEnabled: true, smoothing: 0, detailPreservation: 0, lowLight: 0,
            colorNoiseReduction: 0, glow: 0, evenness: 0, warmth: 0, temporalStability: 0
        )
        let amounts = PortraitProcessor.resolveAmounts(
            for: settings, luminance: 0)
        #expect(amounts.smoothing == 0)
        #expect(amounts.lumaNoise == 0)
        #expect(amounts.chromaBlur == 0)
        #expect(amounts.exposureLift == 0)
        #expect(amounts.shadowLift == 0)
        #expect(amounts.glow == 0)
        #expect(amounts.warmth == 0)
        #expect(amounts.evenness == 0)
    }
}
