/// Observable float popup state driven by BEAM gui_float_popup messages.
///
/// Float popups are centered, bordered windows showing buffer content
/// (e.g. *Help* buffer). The BEAM sends the title and content lines;
/// the GUI renders natively with SwiftUI.

import SwiftUI

@MainActor
@Observable
final class FloatPopupState {
    var visible: Bool = false
    var title: String = ""
    var width: Int = 0
    var height: Int = 0
    var lines: [String] = []

    func update(visible: Bool, width: UInt16, height: UInt16, title: String, lines: [String]) {
        self.visible = visible
        self.width = Int(width)
        self.height = Int(height)
        self.title = title
        self.lines = lines
    }

    func hide() {
        visible = false
        lines = []
    }
}
