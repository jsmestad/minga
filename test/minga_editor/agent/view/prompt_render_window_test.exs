defmodule MingaEditor.Agent.View.PromptRenderWindowTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.UI.Theme
  alias MingaEditor.VimState

  describe "prompt_window_id/0" do
    test "returns reserved window ID 65534" do
      assert PromptRenderWindow.prompt_window_id() == 65_534
    end
  end

  describe "visible_rows/2" do
    test "returns 1 for empty prompt" do
      {:ok, buf} = Buffer.start_link(content: "")
      panel = %UIState.Panel{prompt_buffer: buf}
      assert PromptRenderWindow.visible_rows(panel, 40) == 1
    end

    test "returns line count for multi-line prompt" do
      {:ok, buf} = Buffer.start_link(content: "line 1\nline 2\nline 3")
      panel = %UIState.Panel{prompt_buffer: buf}
      assert PromptRenderWindow.visible_rows(panel, 40) == 3
    end

    test "clamps to max 8 visible rows" do
      lines = Enum.map_join(1..20, "\n", fn i -> "line #{i}" end)
      {:ok, buf} = Buffer.start_link(content: lines)
      panel = %UIState.Panel{prompt_buffer: buf}
      assert PromptRenderWindow.visible_rows(panel, 40) == 8
    end

    test "accounts for word wrap at narrow widths" do
      {:ok, buf} = Buffer.start_link(content: "a very long line that should wrap at 10 chars")
      panel = %UIState.Panel{prompt_buffer: buf}
      # Line is ~45 chars, inner width 10 -> ~5 visual lines
      rows = PromptRenderWindow.visible_rows(panel, 10)
      assert rows > 1
    end
  end

  describe "build/3" do
    test "returns nil for zero inner_width" do
      # Can't build without any test state, but we can verify the guard
      assert PromptRenderWindow.build(%{}, 0) == nil
    end

    test "builds an agent prompt render window with cursor state" do
      ctx = prompt_ctx("hello", input_focused: true, cursor: {0, 5}, mode: :insert)
      model = PromptRenderWindow.build(ctx, 40, {10, 2, 40, 3})

      assert model.window_id == 65_534
      assert model.content_kind == :agent_prompt
      assert model.rect == {10, 2, 40, 3}
      assert model.cursor_visible == true
      assert model.cursor_shape == :beam
      assert model.cursor_row == 0
      assert model.cursor_col == 5
      assert Enum.map(model.rows, & &1.text) == ["hello"]
    end

    test "maps visual selection into prompt display coordinates" do
      ctx =
        prompt_ctx("abcdef",
          input_focused: true,
          cursor: {0, 4},
          mode: :visual,
          mode_state: %{visual_start: {0, 1}}
        )

      model = PromptRenderWindow.build(ctx, 40, {0, 0, 40, 1})

      assert model.selection.type == :char
      assert model.selection.start_row == 0
      assert model.selection.start_col == 1
      assert model.selection.end_row == 0
      assert model.selection.end_col == 4
    end

    test "renders collapsed paste placeholders as prompt pill rows" do
      ctx =
        prompt_ctx("before\n\0PASTE:0\nafter",
          pasted_blocks: [%{text: "one\ntwo\nthree", expanded: false}]
        )

      model = PromptRenderWindow.build(ctx, 40, {0, 0, 40, 3})

      assert Enum.map(model.rows, & &1.text) == ["before", "󰆏 [pasted 3 lines]", "after"]
      assert hd(Enum.at(model.rows, 1).spans).bg != hd(hd(model.rows).spans).bg
    end
  end

  defp prompt_ctx(text, opts) do
    {:ok, buf} = Buffer.start_link(content: text)
    Buffer.move_to(buf, Keyword.get(opts, :cursor, {0, 0}))

    panel = %UIState.Panel{
      prompt_buffer: buf,
      input_focused: Keyword.get(opts, :input_focused, false),
      pasted_blocks: Keyword.get(opts, :pasted_blocks, [])
    }

    editing =
      VimState.transition(
        VimState.new(),
        Keyword.get(opts, :mode, :normal),
        Keyword.get(opts, :mode_state, nil)
      )

    %ViewContext{
      ui_state: %UIState{panel: panel},
      capabilities: Capabilities.default(),
      theme: Theme.get!(:doom_one),
      editing: editing,
      buffers: nil,
      agent_status: :idle,
      pending_approval: nil
    }
  end

  describe "visible_rows/2 with paste placeholders" do
    test "paste placeholder counts as one visual row" do
      # Insert a paste placeholder token into the buffer
      {:ok, buf} = Buffer.start_link(content: "before\n\0PASTE:0\nafter")

      panel = %UIState.Panel{
        prompt_buffer: buf,
        pasted_blocks: [%{text: "line1\nline2\nline3\nline4\nline5", expanded: false}]
      }

      # 3 logical lines (before, placeholder, after) -> 3 visible rows
      assert PromptRenderWindow.visible_rows(panel, 40) == 3
    end
  end
end
