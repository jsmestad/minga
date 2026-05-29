defmodule MingaEditor.Frontend.Emit.TUI.CellCommandEncoder do
  @moduledoc """
  Encodes TUI cell-grid render model cells into frontend protocol commands.

  This is the TUI adapter edge for cell output. It intentionally consumes `Minga.RenderModel.Cell` rather than `MingaEditor.DisplayList` so `DisplayList.Frame` does not remain the production TUI render product.
  """

  alias Minga.Core.Face
  alias Minga.RenderModel.Cell
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.UI.FontRegistry

  @doc "Encodes cells into draw_text or draw_styled_text protocol commands."
  @spec encode([Cell.t()]) :: [binary()]
  def encode(cells) when is_list(cells) do
    cells
    |> Enum.reduce([], fn %Cell{} = cell, acc -> prepend_cell_command(cell, acc) end)
    |> Enum.reverse()
  end

  @spec prepend_cell_command(Cell.t(), [binary()]) :: [binary()]
  defp prepend_cell_command(%Cell{col: col}, acc) when col < 0, do: acc

  defp prepend_cell_command(%Cell{row: row, col: col, text: text, face: %Face{} = face}, acc) do
    if simple_draw_face?(face) do
      [Protocol.encode_draw_face(row, col, text, face) | acc]
    else
      style = face |> Face.to_style() |> resolve_font_family()
      [Protocol.encode_draw_smart(row, col, text, style) | acc]
    end
  end

  @spec resolve_font_family(keyword()) :: keyword()
  defp resolve_font_family(style) do
    case Keyword.pop(style, :font_family) do
      {nil, _rest} ->
        style

      {family, rest} ->
        resolve_registered_font_family(family, rest, FontRegistry.process_registry())
    end
  end

  @spec resolve_registered_font_family(String.t(), keyword(), FontRegistry.t() | nil) :: keyword()
  defp resolve_registered_font_family(_family, rest, nil), do: rest

  defp resolve_registered_font_family(family, rest, registry) do
    {font_id, updated_registry, _new?} = FontRegistry.get_or_register(registry, family)
    FontRegistry.put_process_registry(updated_registry)

    if font_id > 0, do: [{:font_id, font_id} | rest], else: rest
  end

  @spec simple_draw_face?(Face.t()) :: boolean()
  defp simple_draw_face?(%Face{} = face) do
    face.strikethrough != true and (face.underline_style == nil or face.underline_style == :line) and
      face.underline_color == nil and (face.blend == nil or face.blend == 100) and
      face.font_family == nil and (face.font_weight == nil or face.font_weight == :regular)
  end
end
