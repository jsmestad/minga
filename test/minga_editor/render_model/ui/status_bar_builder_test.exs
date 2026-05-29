defmodule MingaEditor.RenderModel.UI.StatusBarBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Workspace
  alias MingaEditor.RenderModel.UI.StatusBarBuilder

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

  defp minimal_theme do
    MingaEditor.UI.Theme.get!(:doom_one)
  end

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
    test "returns a semantic StatusBar model" do
      model = StatusBarBuilder.build(minimal_buffer_data(), minimal_theme(), minimal_ctx())

      assert %StatusBar{content_kind: :buffer, data: data} = model
      assert data.file.name == "test.ex"
      assert is_binary(data.file.icon)
      assert is_integer(data.file.icon_color)
    end

    test "includes active workspace summary when available" do
      model = StatusBarBuilder.build(minimal_buffer_data(), minimal_theme(), minimal_ctx())

      assert %Workspace{id: 0, kind: :manual} = model.workspace
    end
  end
end
