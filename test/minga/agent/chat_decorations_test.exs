defmodule Minga.Agent.ChatDecorationsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.ChatDecorations
  alias Minga.Core.Decorations

  defp test_theme do
    Minga.UI.Theme.agent_theme(Minga.UI.Theme.get!(Minga.UI.Theme.default()))
  end

  describe "build_decorations/3" do
    test "user message gets header block decoration" do
      decs = Decorations.new()
      messages = [{:user, "hello world"}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
    end

    test "assistant message gets header block decoration" do
      decs = Decorations.new()
      messages = [{:assistant, "I can help with that."}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
    end

    test "collapsed thinking gets fold region" do
      decs = Decorations.new()
      messages = [{:thinking, "analyzing the code...", true}]
      offsets = [{0, 0, 5}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_fold_regions?(result)
      fold = hd(Decorations.closed_fold_regions(result))
      assert fold.start_line == 0
      assert fold.end_line == 4
    end

    test "open thinking gets no fold region" do
      decs = Decorations.new()
      messages = [{:thinking, "analyzing...", false}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      refute Decorations.has_fold_regions?(result)
    end

    test "tool call gets header block and output fold" do
      tc = %MingaAgent.ToolCall{
        id: "tc-1",
        name: "read_file",
        status: :complete,
        result: "file content here\nline 2\nline 3",
        collapsed: false
      }

      decs = Decorations.new()
      messages = [{:tool_call, tc}]
      offsets = [{0, 0, 6}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
      # Tool output fold region (open by default, collapsible with za)
      assert Decorations.has_fold_regions?(result)
    end

    test "running tool call has no fold (still streaming)" do
      tc = %MingaAgent.ToolCall{
        id: "tc-2",
        name: "shell",
        status: :running,
        result: "",
        collapsed: false
      }

      decs = Decorations.new()
      messages = [{:tool_call, tc}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      refute Decorations.has_fold_regions?(result)
    end

    test "tool call awaiting approval shows approval prompt in header" do
      tc = %MingaAgent.ToolCall{
        id: "tc_123",
        name: "write_file",
        status: :running,
        result: "",
        collapsed: false
      }

      decs = Decorations.new()
      messages = [{:tool_call, tc}]
      offsets = [{0, 0, 1}]

      pending_approval = %{tool_call_id: "tc_123", name: "write_file", args: %{}}

      result =
        ChatDecorations.build_decorations(decs, messages, offsets, test_theme(),
          pending_approval: pending_approval
        )

      # Header block decoration should contain approval prompt text
      {above, _below} = Decorations.blocks_for_line(result, 0)
      assert length(above) == 1

      [block_dec] = above
      rendered = block_dec.render.(80)

      # The rendered output should contain the approval prompt segments
      rendered_text = Enum.map_join(rendered, "", fn {text, _style} -> text end)
      assert rendered_text =~ "Approve?"
      assert rendered_text =~ "[y]"
      assert rendered_text =~ "[n]"
    end

    test "tool call without matching approval shows normal header" do
      tc = %MingaAgent.ToolCall{
        id: "tc_456",
        name: "read_file",
        status: :running,
        result: "",
        collapsed: false
      }

      decs = Decorations.new()
      messages = [{:tool_call, tc}]
      offsets = [{0, 0, 1}]

      # Different tool_call_id, should not show approval
      pending_approval = %{tool_call_id: "tc_999", name: "other_tool", args: %{}}

      result =
        ChatDecorations.build_decorations(decs, messages, offsets, test_theme(),
          pending_approval: pending_approval
        )

      {above, _below} = Decorations.blocks_for_line(result, 0)
      assert length(above) == 1

      [block_dec] = above
      rendered = block_dec.render.(80)
      rendered_text = Enum.map_join(rendered, "", fn {text, _style} -> text end)
      refute rendered_text =~ "Approve?"
    end

    test "multiple messages get independent decorations" do
      decs = Decorations.new()

      messages = [
        {:user, "hi"},
        {:assistant, "hello"},
        {:user, "thanks"}
      ]

      offsets = [{0, 0, 3}, {1, 5, 3}, {2, 10, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      {above, _below} = Decorations.blocks_for_line(result, 0)
      assert length(above) == 1

      {above2, _} = Decorations.blocks_for_line(result, 5)
      assert length(above2) == 1

      {above3, _} = Decorations.blocks_for_line(result, 10)
      assert length(above3) == 1
    end

    test "usage messages get a dim highlight" do
      decs = Decorations.new()
      messages = [{:usage, %MingaAgent.TurnUsage{input: 100, output: 50, cost: 0.001}}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      # Usage gets a highlight decoration for dim styling, but no block decorations
      {above, below} = Decorations.blocks_for_line(result, 0)
      assert above == []
      assert below == []
      refute Decorations.empty?(result)
    end
  end

  describe "no regex delimiter dimming in decorations" do
    test "assistant messages have no :chat_md_delimiters group highlights" do
      decs = Decorations.new()
      messages = [{:assistant, "This is **bold** and `code` and # heading"}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      # Delimiter dimming is now handled by tree-sitter syntax theme overrides,
      # not by ChatDecorations regex scanning. No :chat_md_delimiters group
      # should exist in the decoration layer.
      highlights = Decorations.highlights_for_line(result, 0)
      delimiter_highlights = Enum.filter(highlights, fn hl -> hl.group == :chat_md_delimiters end)
      assert delimiter_highlights == []
    end
  end
end
