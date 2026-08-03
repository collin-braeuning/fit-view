import Foundation
import Testing
@testable import FitViewCore

private func makeStore(suiteName: String = UUID().uuidString) -> DeviceNicknameStore {
    DeviceNicknameStore(defaults: UserDefaults(suiteName: suiteName)!)
}

@Suite("DeviceNicknameStore")
struct DeviceNicknameStoreTests {
    @Test("a fresh store resolves any raw name to itself")
    func startsEmpty() {
        let store = makeStore()
        #expect(store.all().isEmpty)
        #expect(store.resolvedLabel(for: "Polar Verity Sense") == "Polar Verity Sense")
    }

    @Test("key(for:) strips spaces and lowercases")
    func keyNormalization() {
        #expect(DeviceNicknameStore.key(for: "Polar Verity Sense") == "polarveritysense")
        #expect(DeviceNicknameStore.key(for: "polarveritysense") == "polarveritysense")
        #expect(DeviceNicknameStore.key(for: "POLAR VERITY SENSE") == "polarveritysense")
    }

    @Test("a set nickname is resolved, and persists across a fresh instance over the same defaults")
    func setNicknamePersists() {
        let suiteName = UUID().uuidString
        let writer = makeStore(suiteName: suiteName)
        #expect(writer.setNickname("polarSense", forRawDeviceName: "Polar Verity Sense"))
        #expect(writer.resolvedLabel(for: "Polar Verity Sense") == "polarSense")

        let reader = makeStore(suiteName: suiteName)
        #expect(reader.resolvedLabel(for: "Polar Verity Sense") == "polarSense")
    }

    @Test("resolution is normalized: a differently-spaced or -cased raw name still resolves")
    func resolutionIsNormalized() {
        let store = makeStore()
        store.setNickname("polarSense", forRawDeviceName: "Polar Verity Sense")
        #expect(store.resolvedLabel(for: "polarveritysense") == "polarSense")
        #expect(store.resolvedLabel(for: "POLAR VERITY SENSE") == "polarSense")
    }

    @Test("renaming an already-nicknamed device (a second hop) resolves through both hops")
    func multiHopResolution() {
        let store = makeStore()
        store.setNickname("polarSense", forRawDeviceName: "Polar Verity Sense")
        store.setNickname("Reference HR", forRawDeviceName: "polarSense")

        #expect(store.resolvedLabel(for: "Polar Verity Sense") == "Reference HR")
        #expect(store.resolvedLabel(for: "polarSense") == "Reference HR")
    }

    @Test("a rename that would create a two-hop cycle is rejected")
    func rejectsATwoHopCycle() {
        let store = makeStore()
        #expect(store.setNickname("b", forRawDeviceName: "a"))
        // b -> a would close the loop a -> b -> a.
        #expect(store.setNickname("a", forRawDeviceName: "b") == false)

        #expect(store.resolvedLabel(for: "a") == "b")
        #expect(store.resolvedLabel(for: "b") == "b", "the rejected write must not have been applied")
    }

    @Test("a rename that would create a longer cycle is rejected")
    func rejectsALongerCycle() {
        let store = makeStore()
        #expect(store.setNickname("b", forRawDeviceName: "a"))
        #expect(store.setNickname("c", forRawDeviceName: "b"))
        // c -> a would close the loop a -> b -> c -> a.
        #expect(store.setNickname("a", forRawDeviceName: "c") == false)

        #expect(store.resolvedLabel(for: "a") == "c")
    }

    @Test("a non-cyclic rename of an already-nicknamed device's target is allowed")
    func allowsANonCyclicChainExtension() {
        let store = makeStore()
        store.setNickname("b", forRawDeviceName: "a")
        // b -> z does not loop back to a.
        #expect(store.setNickname("z", forRawDeviceName: "b"))
        #expect(store.resolvedLabel(for: "a") == "z")
    }
}
