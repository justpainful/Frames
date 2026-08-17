import Foundation
import Testing
@testable import Frames

@Suite("Adjustments")
struct AdjustmentTests {

    @Test("A new set is neutral")
    func newSetIsNeutral() {
        let set = AdjustmentSet()
        #expect(set.isIdentity)
        #expect(set.activeParameters.isEmpty)
        for parameter in AdjustmentParameter.allCases {
            #expect(set[parameter] == parameter.defaultValue)
        }
    }

    @Test("Values are clamped to each parameter's range")
    func valuesAreClamped() {
        var set = AdjustmentSet()
        set[.exposure] = 5
        #expect(set[.exposure] == 1)

        set[.exposure] = -5
        #expect(set[.exposure] == -1)

        set[.grain] = -1
        #expect(set[.grain] == 0, "grain is unipolar")
    }

    @Test("Setting a value back to neutral clears it")
    func neutralValueClears() {
        var set = AdjustmentSet()
        set[.contrast] = 0.4
        #expect(set.isActive(.contrast))
        set[.contrast] = 0
        #expect(!set.isActive(.contrast))
        #expect(set.isIdentity)
    }

    @Test("Reset removes one parameter, reset all removes every parameter")
    func reset() {
        var set = AdjustmentSet([.exposure: 0.3, .contrast: 0.2, .saturation: -0.4])
        #expect(set.activeParameters.count == 3)

        set.reset(.contrast)
        #expect(set.activeParameters.count == 2)
        #expect(set[.contrast] == 0)

        set.resetAll()
        #expect(set.isIdentity)
    }

    @Test("Active parameters come back in canonical order")
    func activeParametersAreOrdered() {
        let set = AdjustmentSet([.vignette: 0.2, .exposure: 0.3, .saturation: 0.1])
        #expect(set.activeParameters == [.exposure, .saturation, .vignette])
    }

    @Test("Scaling an adjustment set scales every active value")
    func scaling() {
        let set = AdjustmentSet([.exposure: 0.4, .contrast: -0.2])
        let half = set.scaled(by: 0.5)
        #expect(abs(half[.exposure] - 0.2) < 0.0001)
        #expect(abs(half[.contrast] + 0.1) < 0.0001)
    }

    @Test("Interpolation moves smoothly between two sets")
    func interpolation() {
        let a = AdjustmentSet([.exposure: 0])
        let b = AdjustmentSet([.exposure: 0.8])
        let mid = AdjustmentSet.interpolate(a, b, t: 0.5)
        #expect(abs(mid[.exposure] - 0.4) < 0.0001)
        #expect(AdjustmentSet.interpolate(a, b, t: 0)[.exposure] == 0)
        #expect(abs(AdjustmentSet.interpolate(a, b, t: 1)[.exposure] - 0.8) < 0.0001)
    }

    @Test("Merging adds and clamps")
    func merging() {
        let a = AdjustmentSet([.exposure: 0.7])
        let b = AdjustmentSet([.exposure: 0.7, .contrast: 0.2])
        let merged = a.merging(b)
        #expect(merged[.exposure] == 1, "the sum is clamped to the parameter range")
        #expect(abs(merged[.contrast] - 0.2) < 0.0001)
    }

    @Test("Every parameter belongs to exactly one group")
    func groupsPartitionParameters() {
        let grouped = AdjustmentGroup.allCases.flatMap(\.parameters)
        #expect(Set(grouped) == Set(AdjustmentParameter.allCases))
        #expect(grouped.count == AdjustmentParameter.allCases.count)
    }

    @Test("Every parameter has a symbol and a name")
    func metadataIsComplete() {
        for parameter in AdjustmentParameter.allCases {
            #expect(!parameter.displayName.isEmpty)
            #expect(!parameter.symbolName.isEmpty)
            #expect(parameter.range.contains(parameter.defaultValue))
        }
    }
}

@Suite("Filters")
struct FilterCatalogTests {

    @Test("Filter identifiers are unique")
    func identifiersAreUnique() {
        let ids = FilterCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every category has filters")
    func everyCategoryIsPopulated() {
        for category in FilterCategory.allCases {
            #expect(!FilterCatalog.presets(in: category).isEmpty, "\(category.rawValue) is empty")
        }
    }

    @Test("Lookup finds presets, including the neutral one")
    func lookup() {
        #expect(FilterCatalog.preset(id: "none")?.recipe.isNeutral == true)
        #expect(FilterCatalog.preset(id: "noir") != nil)
        #expect(FilterCatalog.preset(id: "does-not-exist") == nil)
    }

    @Test("A filter instance resolves to its preset and clamps intensity")
    func instanceResolution() {
        let instance = FilterInstance(presetID: "vintage", intensity: 3)
        #expect(instance.intensity == 1)
        #expect(instance.preset?.displayName == FilterCatalog.preset(id: "vintage")?.displayName)
    }

    @Test("Every filter has a display name")
    func namesArePresent() {
        for preset in FilterCatalog.all {
            #expect(!preset.displayName.isEmpty)
        }
    }
}

@Suite("Keyframes")
struct KeyframeTests {

    @Test("An empty set returns the fallback")
    func emptySetUsesFallback() {
        let set = KeyframeSet()
        #expect(set.isEmpty)
        #expect(set.value(.opacity, at: 3, fallback: 0.42) == 0.42)
    }

    @Test("Values interpolate between keyframes")
    func interpolation() {
        var set = KeyframeSet()
        set.setKeyframe(.opacity, value: 0, at: 0, easing: .linear)
        set.setKeyframe(.opacity, value: 1, at: 2, easing: .linear)

        #expect(abs(set.value(.opacity, at: 1, fallback: 0) - 0.5) < 0.0001)
        #expect(set.value(.opacity, at: 0, fallback: 0) == 0)
        #expect(set.value(.opacity, at: 2, fallback: 0) == 1)
    }

    @Test("Values hold outside the keyframed range")
    func valuesHoldAtEdges() {
        var set = KeyframeSet()
        set.setKeyframe(.scale, value: 0.5, at: 1)
        set.setKeyframe(.scale, value: 1.5, at: 3)
        #expect(set.value(.scale, at: 0, fallback: 99) == 0.5)
        #expect(set.value(.scale, at: 10, fallback: 99) == 1.5)
    }

    @Test("Setting a keyframe at an existing time replaces it")
    func replaceAtSameTime() {
        var set = KeyframeSet()
        set.setKeyframe(.rotation, value: 1, at: 2)
        set.setKeyframe(.rotation, value: 2, at: 2)
        #expect(set.track(.rotation)?.keyframes.count == 1)
        #expect(set.value(.rotation, at: 2, fallback: 0) == 2)
    }

    @Test("Removing the last keyframe of a property clears the track")
    func removingClearsTrack() {
        var set = KeyframeSet()
        set.setKeyframe(.volume, value: 0.5, at: 1)
        set.removeKeyframe(.volume, at: 1)
        #expect(set.isEmpty)
        #expect(!set.isAnimated(.volume))
    }

    @Test("Shifting moves every keyframe")
    func shifting() {
        var set = KeyframeSet()
        set.setKeyframe(.positionX, value: 0.2, at: 1)
        set.setKeyframe(.positionX, value: 0.8, at: 3)
        set.shift(by: -1)
        #expect(set.value(.positionX, at: 0, fallback: 0) == 0.2)
        #expect(set.value(.positionX, at: 2, fallback: 0) == 0.8)
    }

    @Test("An animated transform evaluates at a moment")
    func transformEvaluation() {
        var set = KeyframeSet()
        set.setKeyframe(.opacity, value: 0, at: 0, easing: .linear)
        set.setKeyframe(.opacity, value: 1, at: 1, easing: .linear)

        let transform = LayerTransform()
        let evaluated = transform.evaluated(with: set, at: 0.5)
        #expect(abs(evaluated.opacity - 0.5) < 0.0001)
        #expect(evaluated.position == transform.position, "unanimated properties are untouched")
    }

    @Test("Easing curves stay inside 0...1")
    func easingBounds() {
        for easing in KeyframeEasing.allCases {
            for step in 0...10 {
                let t = Double(step) / 10
                let value = easing.apply(t)
                #expect(value >= -0.0001 && value <= 1.0001, "\(easing.rawValue) went out of range at \(t)")
            }
        }
    }
}
