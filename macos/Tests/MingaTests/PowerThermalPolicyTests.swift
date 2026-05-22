import Foundation
import Testing

struct PowerThermalPolicyTests {
    @Test("nominal operation is unthrottled")
    func nominalPolicyIsUnthrottled() {
        let policy = PowerThermalPolicy.policy(lowPowerMode: false, thermalState: .nominal)

        #expect(policy.cursorBlinkMultiplier == 1)
        #expect(policy.levelName == "nominal")
    }

    @Test("low power mode preserves the user's normal blink cadence")
    func lowPowerModePolicyPreservesBlinkCadence() {
        let policy = PowerThermalPolicy.policy(lowPowerMode: true, thermalState: .nominal)

        #expect(policy.cursorBlinkMultiplier == 1)
        #expect(policy.levelName == "low_power")
    }

    @Test("mild thermal pressure preserves blink cadence while stronger pressure slows it")
    func thermalPressureTiersAreProgressive() {
        let fair = PowerThermalPolicy.policy(lowPowerMode: false, thermalState: .fair)
        let serious = PowerThermalPolicy.policy(lowPowerMode: false, thermalState: .serious)
        let critical = PowerThermalPolicy.policy(lowPowerMode: false, thermalState: .critical)

        #expect(fair.cursorBlinkMultiplier == 1)
        #expect(serious.cursorBlinkMultiplier == 3)
        #expect(critical.cursorBlinkMultiplier == 0)
    }

    @Test("thermal state encoding matches BEAM protocol")
    func thermalStateEncoding() {
        #expect(PowerThermalPolicy.encodeThermalState(.nominal) == 0)
        #expect(PowerThermalPolicy.encodeThermalState(.fair) == 1)
        #expect(PowerThermalPolicy.encodeThermalState(.serious) == 2)
        #expect(PowerThermalPolicy.encodeThermalState(.critical) == 3)
    }

    @Test("blink timings scale with saturation")
    func blinkTimingScales() {
        let timing = SystemBlinkTiming(onDuration: 10, offDuration: 20)
        let scaled = timing.scaled(by: 3)

        #expect(scaled.onDuration == 30)
        #expect(scaled.offDuration == 60)
    }
}
