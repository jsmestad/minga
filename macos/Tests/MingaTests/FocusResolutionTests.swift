import Testing
import MingaProtocol

@Suite("Committed focus resolution")
struct FocusResolutionTests {
    @Test("every wire responder resolves without visibility inputs", arguments: Wire.FocusOwner.Responder.allCases)
    func resolves(_ kind: Wire.FocusOwner.Responder) {
        let owner = Wire.FocusOwner(responder: kind.rawValue, surface: 0, windowID: 1, generation: 7)
        #expect(FocusResolution.resolve(committed: owner, lifecycle: FocusLifecycleState()) == kind)
        #expect(FocusResolution.resolve(committed: owner, lifecycle: FocusLifecycleState(nativeModalDepth: 1)) == nil)
        #expect(FocusResolution.resolve(committed: owner, lifecycle: FocusLifecycleState(windowIsKey: false)) == nil)
        #expect(FocusResolution.resolve(committed: owner, lifecycle: FocusLifecycleState(nativeTextEditingActive: true)) == nil)
        #expect(FocusResolution.resolve(committed: owner, lifecycle: FocusLifecycleState(nativeModalDepth: 2)) == nil)
    }

    @Test("missing and unknown owner never invent an editor fallback")
    func missingOwner() {
        #expect(FocusResolution.resolve(committed: nil, lifecycle: FocusLifecycleState()) == nil)
        let unknown = Wire.FocusOwner(responder: 255, surface: 0, windowID: 1, generation: 0)
        #expect(FocusResolution.resolve(committed: unknown, lifecycle: FocusLifecycleState()) == nil)
    }
}
