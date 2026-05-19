defmodule MingaEditor.UserQueryOverrideTest do
  @moduledoc """
  Tests for user-customizable highlight query behavior at the cheapest useful layers.

  Parser aliases live in `Minga.Command.ParserTest`. This file keeps the command-level reload contract and the pure query path fallback.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.HighlightSync
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Highlight.Grammar

  describe ":reload-highlights command" do
    test "resets active highlights and requests a new parse" do
      state = TestHelpers.base_state(content: "defmodule Foo do\nend\n", filetype: :elixir)

      state =
        state
        |> HighlightSync.handle_names(["keyword"])
        |> HighlightSync.handle_spans(1, [%{start_byte: 0, end_byte: 9, capture_id: 0}])

      refute HighlightSync.get_active_highlight(state).spans == {}
      version_before = state.workspace.highlight.version

      state = BufferManagement.execute(state, {:execute_ex_command, {:reload_highlights, []}})

      assert HighlightSync.get_active_highlight(state).spans == {}
      assert state.workspace.highlight.version > version_before
    end
  end

  describe "user query file detection" do
    test "Grammar.query_path falls back to the bundled query" do
      path = Grammar.query_path("elixir")

      assert path != nil
      assert String.contains?(path, "priv/queries/elixir/highlights.scm")
    end
  end
end
