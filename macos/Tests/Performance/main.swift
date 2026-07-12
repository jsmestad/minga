import Foundation

private let warmupIterations = 200
private let measuredIterations = 1_000
private let fixtureRows = 4_096
private let visibleRows = 160

private struct Fixture {
    let payload: Data

    static func make() -> Fixture {
        var data = Data()
        data.reserveCapacity(fixtureRows * 48)
        for row in 0..<fixtureRows {
            var id = UInt32(row).bigEndian
            withUnsafeBytes(of: &id) { data.append(contentsOf: $0) }
            let text = Data(String(format: "row-%04d let value = fixture[%04d]\n", row, row).utf8)
            var length = UInt16(text.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(text)
        }
        return Fixture(payload: data)
    }
}

private func decodeAndApply(_ fixture: Fixture) -> [UInt32: Data] {
    var store: [UInt32: Data] = [:]
    store.reserveCapacity(fixtureRows)
    fixture.payload.withUnsafeBytes { raw in
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var offset = 0
        while offset < raw.count {
            let id = UInt32(base[offset]) << 24 | UInt32(base[offset + 1]) << 16 |
                UInt32(base[offset + 2]) << 8 | UInt32(base[offset + 3])
            let length = Int(base[offset + 4]) << 8 | Int(base[offset + 5])
            offset += 6
            store[id] = Data(bytes: base + offset, count: length)
            offset += length
        }
    }
    return store
}

private func prepareVisibleCommands(_ store: [UInt32: Data]) -> Int {
    var checksum = 0
    var commands: [(Float, Float, Int)] = []
    commands.reserveCapacity(visibleRows)
    for row in 0..<visibleRows {
        let bytes = store[UInt32(row)] ?? Data()
        checksum &+= bytes.count
        commands.append((Float(row * 18), Float(bytes.count * 8), bytes.hashValue))
    }
    return commands.reduce(checksum) { $0 &+ Int($1.0) &+ Int($1.1) &+ $1.2 }
}

private func elapsedMs(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
}

private func percentile(_ samples: [Double], _ ratio: Double) -> Double {
    let sorted = samples.sorted()
    let index = min(max(Int((Double(sorted.count) * ratio).rounded(.up)) - 1, 0), sorted.count - 1)
    return sorted[index]
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: minga-render-performance <baseline.json>\n".utf8))
    exit(2)
}

private let fixture = Fixture.make()
for _ in 0..<warmupIterations {
    let store = decodeAndApply(fixture)
    _ = prepareVisibleCommands(store)
}

var decodeSamples: [Double] = []
var preparationSamples: [Double] = []
var combinedSamples: [Double] = []
decodeSamples.reserveCapacity(measuredIterations)
preparationSamples.reserveCapacity(measuredIterations)
combinedSamples.reserveCapacity(measuredIterations)
var sink = 0

for _ in 0..<measuredIterations {
    var store: [UInt32: Data] = [:]
    decodeSamples.append(elapsedMs { store = decodeAndApply(fixture) })
    preparationSamples.append(elapsedMs { sink &+= prepareVisibleCommands(store) })
    combinedSamples.append(elapsedMs {
        let combinedStore = decodeAndApply(fixture)
        sink &+= prepareVisibleCommands(combinedStore)
    })
}

let measurement = RenderPerformanceMeasurement(
    decodeApplyP50Ms: percentile(decodeSamples, 0.50),
    decodeApplyP95Ms: percentile(decodeSamples, 0.95),
    commandPreparationP50Ms: percentile(preparationSamples, 0.50),
    commandPreparationP95Ms: percentile(preparationSamples, 0.95),
    combinedP50Ms: percentile(combinedSamples, 0.50),
    combinedP95Ms: percentile(combinedSamples, 0.95)
)
let baselineURL = URL(fileURLWithPath: CommandLine.arguments[1])
let baseline = try JSONDecoder().decode(RenderPerformanceBaseline.self, from: Data(contentsOf: baselineURL))
let output = try JSONEncoder().encode(measurement)
print(String(decoding: output, as: UTF8.self))
print(String(format: "decode+apply p50 %.3fms p95 %.3fms | command-prep p50 %.3fms p95 %.3fms | combined p50 %.3fms p95 %.3fms",
             measurement.decodeApplyP50Ms, measurement.decodeApplyP95Ms,
             measurement.commandPreparationP50Ms, measurement.commandPreparationP95Ms,
             measurement.combinedP50Ms, measurement.combinedP95Ms))
print("fixture=native-visible-v1 rows=\(fixtureRows) visible=\(visibleRows) warmup=\(warmupIterations) iterations=\(measuredIterations) os=\(ProcessInfo.processInfo.operatingSystemVersionString) sink=\(sink)")

let failures = RenderPerformanceGate.failures(measurement: measurement, baseline: baseline)
for failure in failures { FileHandle.standardError.write(Data("error: \(failure)\n".utf8)) }
if !failures.isEmpty { exit(1) }
