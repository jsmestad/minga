defmodule MingaEditor.UI.Picker.SymbolSource do
  @moduledoc """
  Picker source for tree-sitter document symbols in the active buffer.

  The source reads the active window's `document_symbols` list, which is populated by the parser from `tags.scm` queries. Buffers without tag support simply return no candidates.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias Minga.Language.Symbol
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Document symbols"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{document_symbols: symbols}) do
    Enum.map(symbols, &format_candidate/1)
  end

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(%Item{id: {row, col}}, %{workspace: %{buffers: %{active: buffer}}} = state)
      when is_integer(row) and is_integer(col) and is_pid(buffer) do
    Buffer.move_to(buffer, {row, col})
    EditorState.sync_active_window_cursor(state)
  end

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: Source.restore_or_keep(state)

  @spec format_candidate(Symbol.t()) :: Item.t()
  defp format_candidate(%Symbol{kind: kind, name: name, range: {row, col, _end_row, _end_col}}) do
    %Item{
      id: {row, col},
      label: "#{kind_icon(kind)} #{name}",
      description: "line #{row + 1}",
      annotation: kind_label(kind)
    }
  end

  @spec kind_icon(Symbol.kind()) :: String.t()
  defp kind_icon(:function), do: "ƒ"
  defp kind_icon(:module), do: "M"
  defp kind_icon(:method), do: "m"
  defp kind_icon(:interface), do: "I"
  defp kind_icon(:test), do: "✓"

  @spec kind_label(Symbol.kind()) :: String.t()
  defp kind_label(:function), do: "function"
  defp kind_label(:module), do: "module"
  defp kind_label(:method), do: "method"
  defp kind_label(:interface), do: "interface"
  defp kind_label(:test), do: "test"
end
