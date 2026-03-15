defmodule Minga.Agent.ChatDecorationsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.ChatDecorations
  alias Minga.Buffer.Decorations

  defp test_theme do
    Minga.Theme.agent_theme(Minga.Theme.get!(Minga.Theme.default()))
  end

  describe "build_decorations/3" do
    test "user message gets header block and background highlight" do
      decs = Decorations.new()
      messages = [{:user, "hello world"}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
      assert Decorations.highlight_count(result) > 0
    end

    test "assistant message gets header block and background highlight" do
      decs = Decorations.new()
      messages = [{:assistant, "I can help with that."}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
      assert Decorations.highlight_count(result) > 0
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
      tc = %{name: "read_file", status: :complete, result: "file content here\nline 2\nline 3"}
      decs = Decorations.new()
      messages = [{:tool_call, tc}]
      offsets = [{0, 0, 6}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
      # Tool output fold region (open by default, collapsible with za)
      assert Decorations.has_fold_regions?(result)
    end

    test "running tool call has no fold (still streaming)" do
      tc = %{name: "shell", status: :running, result: ""}
      decs = Decorations.new()
      messages = [{:tool_call, tc}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      refute Decorations.has_fold_regions?(result)
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

    test "usage messages produce no decorations" do
      decs = Decorations.new()
      messages = [{:usage, %{input: 100, output: 50, cost: 0.001}}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.empty?(result)
    end
  end
end
