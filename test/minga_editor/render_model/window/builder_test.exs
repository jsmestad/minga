defmodule MingaEditor.RenderModel.Window.BuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState
  alias Minga.RenderModel.Window

  import MingaEditor.RenderPipeline.TestHelpers

  defp build_content(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = MingaEditor.RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    Content.build_content(state, scrolls)
  end

  describe "GUI content stage" do
    test "builds a canonical window model and no GUI draw layers" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert %Window{} = wf.window_model
      assert wf.window_model.content_kind == :buffer
      assert Enum.map(wf.window_model.rows, & &1.text) == ["hello", "world"]
      assert wf.gutter == %{}
      assert wf.lines == %{}
      assert wf.tilde_lines == %{}
    end

    test "includes gutter and indent guide models built from current-frame data" do
      state = gui_state(content: "def a do\n  :ok\nend")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.window_model.gutter.window_id == state.workspace.windows.active
      assert wf.window_model.gutter.entries != []
      assert wf.window_model.indent_guides.window_id == state.workspace.windows.active
    end

    test "TUI path keeps draw layers and skips the GUI window model" do
      state = base_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.window_model == nil
      assert map_size(wf.lines) > 0
    end
  end
end
