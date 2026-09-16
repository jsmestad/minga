import Foundation

@main
@MainActor
struct GUISearchNativeBenchmark {
    private static let rounds = 31
    private static let framesPerRound = 1_000

    static func main() throws {
        let revision = CommandLine.arguments.dropFirst().first ?? "unknown"
        let workloads = [UInt32(40), 65_536, 100_000].map(measure)
        let payload: [String: Any] = [
            "schema": "minga.gui_search_native.v1",
            "ticket": 3280,
            "revision": revision,
            "build_mode": "swiftc -O",
            "rounds": rounds,
            "frames_per_round": framesPerRound,
            "units": "nanoseconds",
            "results": workloads,
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func measure(matchCount: UInt32) -> [String: Any] {
        let initial = samples {
            let state = SearchState()
            state.update(active: true, matchCount: matchCount, currentIndex: matchCount, flags: SearchFlags.caseSensitive, query: "needle", sessionID: 1, acknowledgedEditSeq: 0, status: SearchStatus.ready.rawValue)
            precondition(state.matchCount == matchCount)
        }

        let frameState = SearchState()
        frameState.update(active: true, matchCount: matchCount, currentIndex: 1, flags: SearchFlags.caseSensitive, query: "needle", sessionID: 1, acknowledgedEditSeq: 0, status: SearchStatus.ready.rawValue)

        let frames = samples {
            for frame in 0..<framesPerRound {
                let ordinal = matchCount == 0 ? 0 : UInt32(frame % Int(matchCount)) + 1
                frameState.update(active: true, matchCount: matchCount, currentIndex: ordinal, flags: SearchFlags.caseSensitive, query: "needle", sessionID: 1, acknowledgedEditSeq: 0, status: SearchStatus.ready.rawValue)
            }
        }

        let lifecycle = samples {
            for edit in 1...framesPerRound {
                frameState.update(active: true, matchCount: matchCount, currentIndex: 1, flags: SearchFlags.caseSensitive, query: "needle", sessionID: 1, acknowledgedEditSeq: UInt32(edit), status: SearchStatus.loading.rawValue)
                frameState.update(active: true, matchCount: matchCount, currentIndex: 1, flags: SearchFlags.caseSensitive, query: "needle", sessionID: 1, acknowledgedEditSeq: UInt32(edit), status: SearchStatus.rebuilding.rawValue)
                frameState.update(active: true, matchCount: matchCount, currentIndex: 1, flags: SearchFlags.caseSensitive, query: "needle", sessionID: 1, acknowledgedEditSeq: UInt32(edit), status: SearchStatus.ready.rawValue)
            }
        }

        return [
            "match_count": matchCount,
            "initial_publish_ns": percentiles(initial),
            "cursor_1000_frames_ns": percentiles(frames),
            "edit_rebuild_ready_1000_ns": percentiles(lifecycle),
            "wire_payload_bytes": 21 + "needle".utf8.count,
        ]
    }

    private static func samples(_ operation: () -> Void) -> [UInt64] {
        (0..<rounds).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            operation()
            return DispatchTime.now().uptimeNanoseconds - start
        }
    }

    private static func percentiles(_ samples: [UInt64]) -> [String: UInt64] {
        let sorted = samples.sorted()
        return [
            "p50": percentile(sorted, 0.50),
            "p95": percentile(sorted, 0.95),
            "p99": percentile(sorted, 0.99),
        ]
    }

    private static func percentile(_ sorted: [UInt64], _ quantile: Double) -> UInt64 {
        let index = min(Int(ceil(Double(sorted.count) * quantile)) - 1, sorted.count - 1)
        return sorted[index]
    }
}
