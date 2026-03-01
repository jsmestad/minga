defmodule Minga.Editor.Renderer.WhichKey do
  @moduledoc """
  Which-key popup rendering for the editor.
  """

  alias Minga.Editor.Viewport
  alias Minga.Port.Protocol
  alias Minga.WhichKey

  @doc "Renders the which-key popup when `show_whichkey` is true, otherwise returns `[]`."
  @spec render(map(), Viewport.t()) :: [binary()]
  def render(%{show_whichkey: true, whichkey_node: node}, viewport)
      when is_map(node) do
    bindings = WhichKey.bindings_from_node(node)
    lines = WhichKey.render_popup(bindings)

    popup_row = max(0, viewport.rows - 3 - length(lines))

    ([Protocol.encode_draw(popup_row, 0, String.duplicate("─", viewport.cols), fg: 0x888888)] ++
       lines)
    |> Enum.with_index(popup_row + 1)
    |> Enum.map(fn {line_text, row} ->
      padded = String.pad_trailing(line_text, viewport.cols)
      Protocol.encode_draw(row, 0, padded, fg: 0xEEEEEE, bg: 0x333333)
    end)
  end

  def render(_state, _viewport), do: []
end
