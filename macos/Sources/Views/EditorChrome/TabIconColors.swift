import SwiftUI

enum TabIconColors {
    static func color(forFilename filename: String) -> Color? {
        guard let ext = filename.split(separator: ".").last?.lowercased() else { return nil }
        guard let rgb = extensionColors[String(ext)] else { return nil }
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    private static let extensionColors: [String: UInt32] = [
        "ex": 0x9B59B6,
        "exs": 0x9B59B6,
        "eex": 0x9B59B6,
        "heex": 0x9B59B6,
        "rs": 0xDEA584,
        "go": 0x00ADD8,
        "swift": 0xF05138,
        "py": 0x3776AB,
        "js": 0xF7DF1E,
        "jsx": 0xF7DF1E,
        "ts": 0x3178C6,
        "tsx": 0x3178C6,
        "rb": 0xCC342D,
        "md": 0x519ABA,
        "json": 0xCBCB41,
        "yaml": 0xCB171E,
        "yml": 0xCB171E,
        "toml": 0x9C4221,
        "html": 0xE34C26,
        "css": 0x563D7C,
        "scss": 0xC6538C,
        "lua": 0x000080,
        "zig": 0xF69A1B,
        "c": 0x555555,
        "h": 0x555555,
        "cpp": 0xF34B7D,
        "hpp": 0xF34B7D,
        "java": 0xB07219,
        "kt": 0xA97BFF,
        "sh": 0x89E051,
        "bash": 0x89E051,
        "zsh": 0x89E051,
        "vim": 0x019833,
        "sql": 0xE38C00,
        "graphql": 0xE10098,
        "xml": 0x0060AC,
        "txt": 0x6D8086,
        "log": 0x6D8086,
        "lock": 0x6D8086,
        "dockerfile": 0x384D54,
        "proto": 0x6D8086,
        "erl": 0xB83998,
        "hrl": 0xB83998,
    ]
}
