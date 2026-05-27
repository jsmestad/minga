defmodule MingaEditor.RenderModel.UI.StatusBarBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.StatusBarBuilder
  alias Minga.RenderModel.UI.StatusBar
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Session.ChromeState

  @op_gui_status_bar Minga.Protocol.Opcodes.gui_status_bar()

  # Minimal buffer data that satisfies encode_gui_status_bar
  defp minimal_buffer_data do
    {:buffer,
     %{
       mode: :normal,
       mode_state: nil,
       safe_mode: false,
       cursor_line: 0,
       cursor_col: 0,
       line_count: 1,
       file_name: "test.ex",
       filetype: :elixir,
       dirty: false,
       git_branch: nil,
       git_diff_summary: nil,
       diagnostic_counts: nil,
       diagnostic_hint: nil,
       indent_type: :spaces,
       indent_size: 2,
       selection_info: nil,
       lsp_status: :none,
       parser_status: :available,
       buf_index: 1,
       buf_count: 1,
       macro_recording: false,
       agent_status: :inactive,
       active_tool_name: nil,
       agent_theme_colors: nil,
       background_subagent_count: 0,
       active_background_subagent_label: nil,
       status_msg: nil,
       workspace_label: "Default",
       workspace_draft_count: 0,
       workspace_conflict_count: 0,
       merge_conflict_count: 0
     }}
  end

  # Minimal theme for with_modeline_segments
  defp minimal_theme do
    MingaEditor.UI.Theme.get!(:doom_one)
  end

  # Minimal chrome state context (enough for ChromeState.from_editor_state)
  defp minimal_ctx do
    %{
      shell_state: %{tab_bar: nil},
      workspace: %MingaEditor.Session.State{
        viewport: MingaEditor.Viewport.new(24, 80),
        editing: MingaEditor.VimState.new(),
        buffers: %MingaEditor.State.Buffers{active: nil, list: [], active_index: 0},
        windows: %MingaEditor.State.Windows{
          tree: MingaEditor.WindowTree.new(1),
          map: %{},
          active: 1,
          next_id: 2
        },
        highlight: %MingaEditor.State.Highlighting{}
      }
    }
  end

  describe "build/3" do
    test "returns a StatusBar model with pre-encoded binary" do
      sb_data = minimal_buffer_data()
      theme = minimal_theme()
      ctx = minimal_ctx()

      model = StatusBarBuilder.build(sb_data, theme, ctx)

      assert %StatusBar{encoded: encoded} = model
      assert is_binary(encoded)
      assert <<@op_gui_status_bar, _section_count::8, _rest::binary>> = encoded
    end

    test "produces byte-identical output to legacy ProtocolGUI path" do
      sb_data = minimal_buffer_data()
      theme = minimal_theme()
      ctx = minimal_ctx()

      # Legacy path
      sb_data_with_segments =
        MingaEditor.StatusBar.Data.with_modeline_segments(sb_data, theme)

      chrome_state = ChromeState.from_editor_state(ctx)
      legacy_binary = ProtocolGUI.encode_gui_status_bar(sb_data_with_segments, chrome_state)

      # New path
      model = StatusBarBuilder.build(sb_data, theme, ctx)

      assert model.encoded == legacy_binary,
             "StatusBar builder output does not match legacy encoding"
    end
  end
end
