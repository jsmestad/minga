import Foundation

private func usage() -> Never {
    let message = "usage: native-render-compare [--base BASE.json...] --head HEAD.json... | --hosted --head HEAD.json...\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(2)
}

private var baseURLs: [URL] = []
private var headURLs: [URL] = []
// Hosted mode judges HEAD-only runs from a shared runner; it is never inferred from a missing base.
private var hosted = false
private var index = 1
while index < CommandLine.arguments.count {
    if CommandLine.arguments[index] == "--hosted" {
        hosted = true
        index += 1
        continue
    }
    guard index + 1 < CommandLine.arguments.count else { usage() }
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    switch CommandLine.arguments[index] {
    case "--base": baseURLs.append(url)
    case "--head": headURLs.append(url)
    default: usage()
    }
    index += 2
}

private func decode(_ urls: [URL]) throws -> [NativeRenderPerformanceMeasurement] {
    try urls.map { url in
        try JSONDecoder().decode(NativeRenderPerformanceMeasurement.self, from: Data(contentsOf: url))
    }
}

if hosted, !baseURLs.isEmpty { usage() }

let baseMeasurements = try decode(baseURLs)
let headMeasurements = try decode(headURLs)
let failures: [String]
if hosted {
    failures = NativeRenderPerformanceGate.hostedFailures(measurements: headMeasurements)
    for (run, measurement) in headMeasurements.enumerated() {
        print(String(
            format: "hosted run %d: gpu_active_time p95 %.2fms, handoff_to_copy_completion p95 %.2fms",
            run + 1, measurement.gpuP95Ms, measurement.completionWallP95Ms
        ))
    }
    if let quietest = NativeRenderPerformanceGate.quietestRun(headMeasurements) {
        print(String(
            format: "hosted verdict over %d runs judges wall-clock p95 on the quietest run: gpu_active_time %.2fms, handoff_to_copy_completion %.2fms",
            headMeasurements.count, quietest.gpuP95Ms, quietest.completionWallP95Ms
        ))
    }
} else if baseMeasurements.isEmpty {
    failures = NativeRenderPerformanceGate.absoluteFailures(measurements: headMeasurements)
} else {
    failures = NativeRenderPerformanceGate.pairedFailures(
        baseMeasurements: baseMeasurements,
        headMeasurements: headMeasurements
    )
}
let pairedRatios = zip(baseMeasurements, headMeasurements).map { base, head in
    head.completionWallP50Ms / base.completionWallP50Ms
}.sorted()
if !pairedRatios.isEmpty {
    let medianRatio = pairedRatios[pairedRatios.count / 2]
    print(String(format: "native handoff-to-copy-completion p50 paired median ratio %.3fx (%d pairs)", medianRatio, pairedRatios.count))
}
for failure in failures {
    FileHandle.standardError.write(Data("error: \(failure)\n".utf8))
}
if !failures.isEmpty { exit(1) }
