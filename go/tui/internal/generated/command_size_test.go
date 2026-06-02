package generated

import "testing"

func TestCommandSizeFramings(t *testing.T) {
	tests := []struct {
		name    string
		payload []byte
		size    int
		status  CommandSizeStatus
	}{
		{"fixed clear", []byte{OPClear}, 1, CommandSizeOK},
		{"fixed set_cursor", []byte{OPSetCursor, 0, 0, 0, 0}, 5, CommandSizeOK},
		{"fixed gutter_sep", []byte{OPGuiGutterSep, 0, 0, 0, 0, 0}, 6, CommandSizeOK},
		// gui_indent_guides: the opcode that previously desynced the Go reader.
		{"len16 indent_guides", []byte{OPGuiIndentGuides, 0x00, 0x06, 1, 2, 3, 4, 5, 6}, 9, CommandSizeOK},
		{"len16 set_title", append([]byte{OPSetTitle, 0x00, 0x03}, []byte("abc")...), 6, CommandSizeOK},
		{"len32 file_tree", []byte{OPGuiFileTree, 0, 0, 0, 2, 0xAA, 0xBB}, 7, CommandSizeOK},
		{"sectioned status_bar", []byte{OPGuiStatusBar, 1, 0x01, 0x00, 0x02, 0xAA, 0xBB}, 7, CommandSizeOK},
		{"custom git_status", []byte{OPGuiGitStatus, 0, 0, 0, 0}, 0, CommandSizeCustom},
		{"incomplete len16", []byte{OPGuiIndentGuides, 0x00}, 0, CommandSizeIncomplete},
		{"incomplete len16 body", []byte{OPGuiIndentGuides, 0x00, 0x06, 1, 2}, 0, CommandSizeIncomplete},
		{"empty", []byte{}, 0, CommandSizeIncomplete},
		// Forward-compatibility: an unknown opcode >= 0x90 is sized as len16.
		{"forward-compat unknown", []byte{0xB7, 0x00, 0x02, 0xAA, 0xBB}, 5, CommandSizeOK},
		// An unknown low opcode cannot be sized.
		{"unknown low", []byte{0x44, 0x00}, 0, CommandSizeUnknown},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			size, status := CommandSize(tc.payload)
			if status != tc.status {
				t.Fatalf("status = %v, want %v", status, tc.status)
			}
			if status == CommandSizeOK && size != tc.size {
				t.Fatalf("size = %d, want %d", size, tc.size)
			}
		})
	}
}
