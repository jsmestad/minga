defmodule MingaEditor.UI.Picker.SymbolSourceTest do
  @moduledoc """
  Tests for the document symbol picker source.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Language.Symbol
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.SymbolSource
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  describe "candidates/1" do
    test "returns no candidates when the active window has no document symbols" do
      ctx = base_state() |> Context.from_editor_state()

      assert SymbolSource.candidates(ctx) == []
    end

    test "formats symbols with jump position, name, kind, and one-based line" do
      symbol = %Symbol{kind: :function, name: "run", range: {2, 4, 3, 8}}
      ctx = [symbol] |> state_with_symbols() |> Context.from_editor_state()

      assert [item] = SymbolSource.candidates(ctx)
      assert %Item{id: {2, 4}, label: label, description: "line 3", annotation: "function"} = item
      assert String.contains?(label, "run")
    end
  end

  describe "on_select/2" do
    test "moves the active buffer cursor to the selected symbol start" do
      state = base_state(content: "one\ntwo\nthree")

      new_state = SymbolSource.on_select(%Item{id: {2, 1}, label: "ƒ run"}, state)

      assert new_state == EditorState.sync_active_window_cursor(state)
      assert Buffer.cursor(state.workspace.buffers.active) == {2, 1}
    end
  end

  @spec state_with_symbols([Symbol.t()]) :: EditorState.t()
  defp state_with_symbols(symbols) do
    state = base_state()
    win_id = state.workspace.windows.active
    EditorState.update_window(state, win_id, &Window.set_document_symbols(&1, symbols))
  end
end
