pub mod board;

#[cfg(test)]
mod tests {
    use super::board::{decode_board, render_lines};

    fn packet() -> Vec<u8> {
        let mut packet = vec![0x87, 1, 0, 0, 0, 7, 0, 1, 0, 0, 0];
        packet.extend_from_slice(&[0, 0, 0, 7, 3, 2, 0, 8]);
        packet.extend_from_slice(b"fix auth");
        packet.push(8);
        packet.extend_from_slice(b"claude-4");
        packet.extend_from_slice(&[0, 0, 0, 42, 1, 0, 8]);
        packet.extend_from_slice(b"lib/a.ex");
        packet.extend_from_slice(&[2, 0, 0, 0xFF, 0xFF]);
        // Trailing zoomed_card_id u32 (0 = grid view, not zoomed).
        packet.extend_from_slice(&[0, 0, 0, 0]);
        packet
    }

    fn zoomed_packet() -> Vec<u8> {
        let mut packet = vec![0x87, 0, 0, 0, 0, 7, 0, 1, 0, 0, 0];
        packet.extend_from_slice(&[0, 0, 0, 7, 1, 2, 0, 8]);
        packet.extend_from_slice(b"fix auth");
        packet.push(8);
        packet.extend_from_slice(b"claude-4");
        packet.extend_from_slice(&[0, 0, 0, 42, 1, 0, 8]);
        packet.extend_from_slice(b"lib/a.ex");
        packet.extend_from_slice(&[2, 0, 0, 0xFF, 0xFF]);
        packet.extend_from_slice(&[0, 0, 0, 7]);
        packet
    }

    #[test]
    fn decodes_board_payload() {
        let bytes = packet();
        let (board, size) = decode_board(&bytes).unwrap();
        assert_eq!(size, bytes.len());
        assert_eq!(board.visible, 1);
        assert_eq!(board.focused_card_id, 7);
        assert_eq!(board.zoomed_card_id, 0);
        assert_eq!(board.cards.len(), 1);
        let card = &board.cards[0];
        assert_eq!(card.id, 7);
        assert_eq!(card.status, 3);
        assert_eq!(card.flags, 2);
        assert_eq!(card.task, "fix auth");
        assert_eq!(card.model, "claude-4");
        assert_eq!(card.recent_files, ["lib/a.ex"]);
    }

    #[test]
    fn decodes_zoomed_card_id() {
        let bytes = zoomed_packet();
        let (board, size) = decode_board(&bytes).unwrap();
        assert_eq!(size, bytes.len());
        assert_eq!(board.visible, 0);
        assert_eq!(board.zoomed_card_id, 7);
    }

    #[test]
    fn tolerates_legacy_packet_without_trailer() {
        let mut bytes = packet();
        bytes.truncate(bytes.len() - 4); // drop the zoomed_card_id trailer
        let (board, size) = decode_board(&bytes).unwrap();
        assert_eq!(size, bytes.len());
        assert_eq!(board.zoomed_card_id, 0);
    }

    #[test]
    fn renders_summary_lines() {
        let (board, _) = decode_board(&packet()).unwrap();
        assert_eq!(
            render_lines(&board, 2),
            ["Board  1 cards", "> needs you  fix auth"]
        );
    }
}
