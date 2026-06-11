import Foundation
import SwiftUI

@MainActor
func registerBundledRuntimeExtension0(into registry: FrontendExtensionRuntimeRegistry, encoder: InputEncoder?, theme: ThemeColors) {
    BoardFrontendRuntime.register(into: registry, encoder: encoder, theme: theme)
}

@MainActor
final class BoardFrontendRuntime {
    private static let extensionID = "minga_board"
    private static let channel = "board"
    private static let state = BoardState()
    private static let dispatchSheet = DispatchSheetState()

    static func register(into registry: FrontendExtensionRuntimeRegistry, encoder: InputEncoder?, theme: ThemeColors) {
        registry.register(
            extensionID: extensionID,
            decoder: { message in
                guard message.channel == channel else { return }
                guard let decoded = decodeBoardPayload(message.payload) else { return }
                state.update(
                    visible: decoded.visible,
                    focusedCardId: decoded.focusedCardID,
                    cards: decoded.cards,
                    filterMode: decoded.filterMode,
                    filterText: decoded.filterText,
                    zoomedCardId: decoded.zoomedCardID
                )
            },
            view: { context in
                AnyView(
                    Group {
                        if state.visible {
                            BoardView(
                                state: state,
                                dispatchSheet: dispatchSheet,
                                theme: context.theme,
                                encoder: context.encoder,
                                namespace: context.namespace
                            )
                        } else if let card = state.zoomedCard {
                            // Grid hidden but a card is zoomed: render the zoom
                            // header at the top over the editor. The editor body
                            // itself renders through the window pipeline; this is
                            // a contextual header only, no cell-grid path (#2328).
                            VStack(spacing: 0) {
                                BoardZoomHeader(card: card, theme: context.theme)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                )
            }
        )
    }

    struct DecodedBoard {
        let visible: Bool
        let focusedCardID: UInt32
        let filterMode: Bool
        let filterText: String
        let cards: [BoardCard]
        // Card the user is zoomed into, or 0 in grid view. Non-zero means the
        // grid is hidden (visible false) but the zoom header should render the
        // card identity + ESC affordance over the editor (ticket #2328).
        let zoomedCardID: UInt32
    }

    static var stateForTesting: BoardState {
        state
    }

    static func resetForTesting() {
        state.update(visible: false, focusedCardId: 0, cards: [], filterMode: false, filterText: "")
    }

    static func decodeBoardPayload(_ data: Data) -> DecodedBoard? {
        guard data.count >= 11, data[data.startIndex] == 0x87 else { return nil }
        var pos = data.startIndex + 1
        let visible = data[pos] != 0
        pos += 1
        let focusedCardID = readU32(data, pos)
        pos += 4
        let cardCount = Int(readU16(data, pos))
        pos += 2
        let filterMode = data[pos] != 0
        pos += 1
        guard let filterText = readString16(data, &pos, data.endIndex) else { return nil }

        var cards: [BoardCard] = []
        cards.reserveCapacity(cardCount)

        for _ in 0..<cardCount {
            guard pos + 6 <= data.endIndex else { return nil }
            let cardID = readU32(data, pos)
            pos += 4
            let status = CardStatus(rawValue: data[pos]) ?? .idle
            pos += 1
            let flags = data[pos]
            pos += 1
            guard let task = readString16(data, &pos, data.endIndex) else { return nil }
            guard pos + 1 <= data.endIndex else { return nil }
            let modelLen = Int(data[pos])
            pos += 1
            guard pos + modelLen + 5 <= data.endIndex else { return nil }
            let model = String(data: data[pos..<(pos + modelLen)], encoding: .utf8) ?? ""
            pos += modelLen
            let timestamp = readU32(data, pos)
            pos += 4
            let fileCount = Int(data[pos])
            pos += 1
            var files: [String] = []
            files.reserveCapacity(fileCount)
            for _ in 0..<fileCount {
                guard let file = readString16(data, &pos, data.endIndex) else { return nil }
                files.append(file)
            }
            guard pos + 1 <= data.endIndex else { return nil }
            let sparklineCount = Int(data[pos])
            pos += 1
            guard pos + sparklineCount * 2 <= data.endIndex else { return nil }
            var sparkline: [Float] = []
            sparkline.reserveCapacity(sparklineCount)
            for _ in 0..<sparklineCount {
                let raw = readU16(data, pos)
                pos += 2
                sparkline.append(Float(raw) / 65_535.0)
            }

            cards.append(BoardCard(
                id: cardID,
                status: status,
                isYouCard: flags & 0x01 != 0,
                isFocused: flags & 0x02 != 0,
                task: task,
                model: model,
                dispatchTimestamp: timestamp,
                recentFiles: files,
                sparkline: sparkline
            ))
        }

        // Trailing zoomed_card_id u32 (0 = grid view). Tolerate older BEAMs that
        // omit the trailer by defaulting to 0 rather than failing the decode.
        var zoomedCardID: UInt32 = 0
        if pos + 4 <= data.endIndex {
            zoomedCardID = readU32(data, pos)
            pos += 4
        }

        return DecodedBoard(visible: visible, focusedCardID: focusedCardID, filterMode: filterMode, filterText: filterText, cards: cards, zoomedCardID: zoomedCardID)
    }

    private static func readString16(_ data: Data, _ pos: inout Int, _ end: Int) -> String? {
        guard pos + 2 <= end else { return nil }
        let length = Int(readU16(data, pos))
        pos += 2
        guard pos + length <= end else { return nil }
        let value = String(data: data[pos..<(pos + length)], encoding: .utf8) ?? ""
        pos += length
        return value
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}

extension InputEncoder {
    func sendBoardSelectCard(id: UInt32) {
        sendExtensionAction(extensionID: "minga_board", action: "select_card", payload: boardU32(id))
    }

    func sendBoardCloseCard(id: UInt32) {
        sendExtensionAction(extensionID: "minga_board", action: "close_card", payload: boardU32(id))
    }

    func sendBoardReorder(cardId: UInt32, newIndex: UInt16) {
        var payload = boardU32(cardId)
        payload.append(UInt8(newIndex >> 8))
        payload.append(UInt8(newIndex & 0xFF))
        sendExtensionAction(extensionID: "minga_board", action: "reorder", payload: payload)
    }

    func sendBoardDispatchAgent(task: String, model: String) {
        var payload = Data()
        appendBoardString16(&payload, task)
        appendBoardString16(&payload, model)
        sendExtensionAction(extensionID: "minga_board", action: "dispatch_agent", payload: payload)
    }

    private func boardU32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private func appendBoardString16(_ data: inout Data, _ value: String) {
        let bytes = Array(value.utf8.prefix(Int(UInt16.max)))
        data.append(UInt8(bytes.count >> 8))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(contentsOf: bytes)
    }
}
