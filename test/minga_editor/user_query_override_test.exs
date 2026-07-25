defmodule MingaEditor.UserQueryOverrideTest do
  @moduledoc """
  Tests for user-customizable highlight query behavior at the cheapest useful layers.

  Parser aliases live in `Minga.Command.ParserTest`. This file keeps the command-level reload contract and the pure query path fallback.
  """

  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.HighlightSync
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Highlight
  alias Minga.Language.Grammar

  describe ":reload-highlights command" do
    test "resets active highlights and requests a new parse" do
      manager_name = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")

      manager =
        start_supervised!(
          {Minga.Parser.Manager, name: manager_name, parser_path: "/missing/parser"}
        )

      state =
        TestHelpers.base_state(
          content: "defmodule Foo do\nend\n",
          filetype: :elixir,
          parser_manager: manager
        )

      state =
        state
        |> HighlightSync.get_active_highlight()
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [Span.new(0, 9, 0)])
        |> then(&HighlightSync.put_highlight(state, state.workspace.buffers.active, &1))

      refute HighlightSync.get_active_highlight(state).spans == {}

      state = BufferManagement.execute(state, {:execute_ex_command, {:reload_highlights, []}})

      assert HighlightSync.get_active_highlight(state).spans == {}
      assert HighlightSync.get_active_highlight(state).version == 0

      assert is_integer(Minga.Parser.Manager.buffer_id(state.workspace.buffers.active, manager))
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
