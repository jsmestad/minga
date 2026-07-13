import Foundation
import MingaProtocol

private let warmupIterations = 200
private let measuredIterations = 1_000
private let fixtureRows = 65_536
private let visibleRows = 160
private let overscanRows = 2
private let editIndex = fixtureRows / 2

private struct Fixture {
    let base: GUIWindowContent
    let deltaPayload: Data

    static func make() throws -> Fixture {
        let rows = (0..<fixtureRows).map { index in
            let indexText = String(index)
            return GUIVisualRow(
                rowType: .normal,
                rowId: UInt64(index + 1),
                bufLine: UInt32(index),
                contentHash: UInt32(index + 1),
                text: "row-" + indexText + " let value = fixture[" + indexText + "]",
                spans: []
            )
        }
        let presentation = GUIScrollPresentation(
            windowId: 1, resetRequired: false,
            anchorTop: UInt32(editIndex - visibleRows / 2), anchorLeft: 0,
            anchorVisualRowOffset: 0,
            visibleStartLine: UInt32(editIndex - visibleRows / 2),
            visibleEndLine: UInt32(editIndex + visibleRows / 2),
            overscanStartLine: UInt32(editIndex - visibleRows / 2 - overscanRows),
            overscanEndLine: UInt32(editIndex + visibleRows / 2 + overscanRows),
            contentEpoch: 7, layoutGeneration: 1
        )
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, contentEpoch: 7,
            cursorRow: UInt16(visibleRows / 2), cursorCol: 0, cursorShape: .block,
            rows: rows, selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], scrollPresentation: presentation
        )
        let replacement = GUIVisualRow(
            rowType: .normal, rowId: UInt64(editIndex + 1), bufLine: UInt32(editIndex),
            contentHash: UInt32(editIndex + 2), text: "edited production row", spans: []
        )
        return Fixture(base: content, deltaPayload: encodeRowsDelta(replacement))
    }
}

private func appendU16(_ value: UInt16, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

private func appendU32(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

private func appendU64(_ value: UInt64, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

private func appendSection(_ id: UInt8, body: Data, to data: inout Data) {
    data.append(id)
    appendU32(UInt32(body.count), to: &data)
    data.append(body)
}

private func encodeRowsDelta(_ row: GUIVisualRow) -> Data {
    var header = Data()
    appendU16(1, to: &header)
    appendU32(7, to: &header)
    header.append(1)
    appendU16(UInt16(visibleRows / 2), to: &header)
    appendU16(0, to: &header)
    header.append(CursorShape.block.rawValue)
    appendU16(0, to: &header)

    var rowBody = Data()
    rowBody.append(row.rowType.rawValue)
    appendU64(row.rowId, to: &rowBody)
    appendU32(row.bufLine, to: &rowBody)
    appendU32(row.contentHash, to: &rowBody)
    let text = Data(row.text.utf8)
    appendU32(UInt32(text.count), to: &rowBody)
    rowBody.append(text)
    appendU16(0, to: &rowBody)

    var splices = Data()
    appendU32(UInt32(fixtureRows), to: &splices)
    appendU32(UInt32(fixtureRows), to: &splices)
    appendU32(1, to: &splices)
    appendU32(UInt32(editIndex), to: &splices)
    appendU32(1, to: &splices)
    appendU32(1, to: &splices)
    splices.append(1)
    splices.append(rowBody)

    var payload = Data([OP_GUI_WINDOW_ROWS_DELTA, 2])
    appendSection(0x01, body: header, to: &payload)
    appendSection(0x0B, body: splices, to: &payload)
    return payload
}

private func decodeAndApply(_ fixture: Fixture) throws -> GUIWindowContent {
    let (command, size) = try decodeCommand(data: fixture.deltaPayload, offset: 0)
    guard size == fixture.deltaPayload.count, let command,
          case .guiWindowRowsDelta(let delta) = command else {
        throw BenchmarkError.invalidDelta
    }
    return try fixture.base.applyingRowsDeltaChecked(delta).get()
}

private func prepareVisibleCommands(_ content: GUIWindowContent) -> ResidentRenderPreparationResult {
    ResidentRenderPreparation.prepare(
        content: content,
        fallbackVisibleRows: visibleRows,
        overscanRows: overscanRows,
        scrollLeft: Int(content.scrollLeft),
        viewportCols: 160
    )
}

private func consumePreparedCommands(_ prepared: ResidentRenderPreparationResult) -> UInt64 {
    prepared.commands.reduce(UInt64(prepared.decorationsVisited)) { value, command in
        value &+ command.row.rowId &+ UInt64(command.row.text.utf8.count)
            &+ UInt64(command.row.spans.count) &+ UInt64(command.gutterBufferLine)
    }
}

private func elapsedMs(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
}

private func percentile(_ samples: [Double], _ ratio: Double) -> Double {
    let sorted = samples.sorted()
    let index = min(max(Int((Double(sorted.count) * ratio).rounded(.up)) - 1, 0), sorted.count - 1)
    return sorted[index]
}

enum BenchmarkError: Error { case invalidDelta }

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: minga-render-performance <baseline.json>\n".utf8))
    exit(2)
}

private let fixture = try Fixture.make()
for _ in 0..<warmupIterations {
    let content = try decodeAndApply(fixture)
    _ = consumePreparedCommands(prepareVisibleCommands(content))
}

var decodeSamples: [Double] = []
var preparationSamples: [Double] = []
var combinedSamples: [Double] = []
decodeSamples.reserveCapacity(measuredIterations)
preparationSamples.reserveCapacity(measuredIterations)
combinedSamples.reserveCapacity(measuredIterations)
var sink: UInt64 = 0

for _ in 0..<measuredIterations {
    var content = fixture.base
    decodeSamples.append(try elapsedMs { content = try decodeAndApply(fixture) })
    preparationSamples.append(elapsedMs {
        sink &+= consumePreparedCommands(prepareVisibleCommands(content))
    })
    combinedSamples.append(try elapsedMs {
        let combinedContent = try decodeAndApply(fixture)
        sink &+= consumePreparedCommands(prepareVisibleCommands(combinedContent))
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
print("fixture=resident-ordinary-edit-v2 rows=\(fixtureRows) visible=\(visibleRows) overscan=\(overscanRows * 2) warmup=\(warmupIterations) iterations=\(measuredIterations) compiler=swiftc-O os=\(ProcessInfo.processInfo.operatingSystemVersionString) sink=\(sink)")

let failures = RenderPerformanceGate.failures(measurement: measurement, baseline: baseline)
for failure in failures { FileHandle.standardError.write(Data("error: \(failure)\n".utf8)) }
if !failures.isEmpty { exit(1) }
