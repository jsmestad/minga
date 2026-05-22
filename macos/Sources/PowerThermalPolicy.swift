/// Resource-pressure policy for macOS low power mode and thermal state.
///
/// The GUI remains event-driven and lets the BEAM own frame pacing. Under stronger resource pressure,
/// this policy slows or disables cursor blinking so the native surface does less avoidable work while the system is constrained.
import Foundation

struct PowerThermalPolicy: Equatable {
    let cursorBlinkMultiplier: UInt64
    let levelName: String

    static func policy(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> PowerThermalPolicy {
        switch thermalState {
        case .critical:
            return PowerThermalPolicy(cursorBlinkMultiplier: 0, levelName: "critical")
        case .serious:
            return PowerThermalPolicy(cursorBlinkMultiplier: 3, levelName: "serious")
        case .fair:
            return PowerThermalPolicy(cursorBlinkMultiplier: 1, levelName: "fair")
        case .nominal:
            return nominalPolicy(lowPowerMode: lowPowerMode)
        @unknown default:
            return nominalPolicy(lowPowerMode: lowPowerMode)
        }
    }

    static func encodeThermalState(_ thermalState: ProcessInfo.ThermalState) -> UInt8 {
        switch thermalState {
        case .nominal:
            return 0
        case .fair:
            return 1
        case .serious:
            return 2
        case .critical:
            return 3
        @unknown default:
            return 255
        }
    }

    static func thermalStateName(_ thermalState: ProcessInfo.ThermalState) -> String {
        switch thermalState {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private static func nominalPolicy(lowPowerMode: Bool) -> PowerThermalPolicy {
        if lowPowerMode {
            return PowerThermalPolicy(cursorBlinkMultiplier: 1, levelName: "low_power")
        }

        return PowerThermalPolicy(cursorBlinkMultiplier: 1, levelName: "nominal")
    }
}

extension SystemBlinkTiming {
    func scaled(by multiplier: UInt64) -> SystemBlinkTiming {
        guard multiplier > 1 else { return self }
        return SystemBlinkTiming(
            onDuration: onDuration.saturatingMultiplied(by: multiplier),
            offDuration: offDuration.saturatingMultiplied(by: multiplier)
        )
    }
}

private extension UInt64 {
    func saturatingMultiplied(by multiplier: UInt64) -> UInt64 {
        let (result, overflow) = multipliedReportingOverflow(by: multiplier)
        return overflow ? UInt64.max : result
    }
}
