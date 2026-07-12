/// Deterministic native renderer work budgets used by CI tests.
struct RendererComplexityMeasurement: Equatable {
    let fullResets: Int
    let chunksTouched: Int
    let editorRowsVisited: Int
    let visibleRows: Int
    /// Total configured overscan across both viewport edges.
    let overscanRows: Int
    /// Explicitly separate from editor row traversal.
    let decorationsVisited: Int
}

/// Fail-closed comparator for operation counts; never uses elapsed time.
enum RendererComplexityGate {
    static func failures(_ measurement: RendererComplexityMeasurement) -> [String] {
        var failures: [String] = []
        if measurement.fullResets != 0 {
            failures.append("full resets \(measurement.fullResets) must equal 0")
        }
        if measurement.chunksTouched > 4 {
            failures.append("Swift chunks touched \(measurement.chunksTouched) exceeds 4")
        }
        let rowLimit = measurement.visibleRows + measurement.overscanRows
        if measurement.editorRowsVisited > rowLimit {
            failures.append("editor rows visited \(measurement.editorRowsVisited) exceeds \(rowLimit)")
        }
        return failures
    }
}
