import Foundation

private func usage() -> Never {
    FileHandle.standardError.write(Data("usage: native-render-compare --base BASE.json... --head HEAD.json...\n".utf8))
    exit(2)
}

private var baseURLs: [URL] = []
private var headURLs: [URL] = []
private var index = 1
while index < CommandLine.arguments.count {
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

let baseMeasurements = try decode(baseURLs)
let headMeasurements = try decode(headURLs)
let failures = NativeRenderPerformanceGate.pairedFailures(
    baseMeasurements: baseMeasurements,
    headMeasurements: headMeasurements
)
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
