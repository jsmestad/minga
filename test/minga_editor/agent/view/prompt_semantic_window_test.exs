defmodule MingaEditor.Agent.View.PromptSemanticWindowTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.View.PromptSemanticWindow
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer

  describe "prompt_window_id/0" do
    test "returns reserved window ID 65534" do
      assert PromptSemanticWindow.prompt_window_id() == 65_534
    end
  end

  describe "visible_rows/2" do
    test "returns 1 for empty prompt" do
      {:ok, buf} = Buffer.start_link(content: "")
      panel = %UIState.Panel{prompt_buffer: buf}
      assert PromptSemanticWindow.visible_rows(panel, 40) == 1
    end

    test "returns line count for multi-line prompt" do
      {:ok, buf} = Buffer.start_link(content: "line 1\nline 2\nline 3")
      panel = %UIState.Panel{prompt_buffer: buf}
      assert PromptSemanticWindow.visible_rows(panel, 40) == 3
    end

    test "clamps to max 8 visible rows" do
      lines = Enum.map_join(1..20, "\n", fn i -> "line #{i}" end)
      {:ok, buf} = Buffer.start_link(content: lines)
      panel = %UIState.Panel{prompt_buffer: buf}
      assert PromptSemanticWindow.visible_rows(panel, 40) == 8
    end

    test "accounts for word wrap at narrow widths" do
      {:ok, buf} = Buffer.start_link(content: "a very long line that should wrap at 10 chars")
      panel = %UIState.Panel{prompt_buffer: buf}
      # Line is ~45 chars, inner width 10 -> ~5 visual lines
      rows = PromptSemanticWindow.visible_rows(panel, 10)
      assert rows > 1
    end
  end

  describe "build/2" do
    test "returns nil for zero inner_width" do
      # Can't build without any test state, but we can verify the guard
      assert PromptSemanticWindow.build(%{}, 0) == nil
    end
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
      assert PromptSemanticWindow.visible_rows(panel, 40) == 3
    end
  end
end
