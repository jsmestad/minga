defmodule Minga.Frontend.Adapter.GUI.HoverPopupEncoder do
  @moduledoc false

  alias Minga.Core.Face
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.HoverPopup
  alias Minga.RenderModel.UI.HoverPopup.Line
  alias Minga.RenderModel.UI.HoverPopup.Segment

  @op_gui_hover_popup Opcodes.gui_hover_popup()
  @op_gui_hover_action Opcodes.gui_hover_action()
  @syntax_fallback_fg 0xBBC2CF

  @spec encode(HoverPopup.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%HoverPopup{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_hover_popup_fp do
      {encode_command(model), %{caches | last_hover_popup_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(HoverPopup.t()) :: binary()
  def encode_command(%HoverPopup{visible?: false}), do: <<@op_gui_hover_popup, 0::8>>

  def encode_command(%HoverPopup{} = model) do
    focused_byte = if model.focused?, do: 1, else: 0
    line_data = Enum.map(model.content_lines, &encode_line/1)

    hover =
      IO.iodata_to_binary([
        <<@op_gui_hover_popup, 1::8, model.anchor_row::16, model.anchor_col::16, focused_byte::8,
          model.scroll_offset::16, length(model.content_lines)::16>>
        | line_data
      ])

    IO.iodata_to_binary([hover, encode_hover_action(model.open_action_name)])
  end

  @spec fingerprint(HoverPopup.t()) :: term()
  defp fingerprint(%HoverPopup{visible?: false}), do: :hidden

  defp fingerprint(%HoverPopup{} = model) do
    {model.visible?, model.anchor_row, model.anchor_col, model.focused?, model.scroll_offset,
     model.content_lines, model.open_action_name}
  end

  @spec encode_line(Line.t()) :: iodata()
  defp encode_line(%Line{} = line) do
    segment_data = Enum.map(line.segments, &encode_markdown_segment/1)
    line_type_byte = encode_line_type(line.line_type)
    [<<line_type_byte::8, length(line.segments)::16>> | segment_data]
  end

  @spec encode_hover_action(String.t() | nil) :: binary()
  defp encode_hover_action(nil), do: <<@op_gui_hover_action, 1::16, 0::8>>

  defp encode_hover_action(action_name) do
    action_bytes = :erlang.iolist_to_binary([action_name])
    payload_len = 1 + 2 + byte_size(action_bytes)

    <<@op_gui_hover_action, payload_len::16, 1::8, byte_size(action_bytes)::16,
      action_bytes::binary>>
  end

  @spec encode_markdown_segment(Segment.t()) :: binary()
  defp encode_markdown_segment(%Segment{text: text, style: {:syntax, %Face{} = face}}) do
    text_bytes = :erlang.iolist_to_binary([text])
    fg = face.fg || @syntax_fallback_fg
    {r, g, b} = Wire.rgb(fg)
    flags = encode_syntax_flags(face)

    <<13::8, r::8, g::8, b::8, flags::8, byte_size(text_bytes)::16, text_bytes::binary>>
  end

  defp encode_markdown_segment(%Segment{} = segment) do
    style_byte = encode_markdown_style(segment.style)
    text_bytes = :erlang.iolist_to_binary([segment.text])
    <<style_byte::8, byte_size(text_bytes)::16, text_bytes::binary>>
  end

  @spec encode_syntax_flags(Face.t()) :: non_neg_integer()
  defp encode_syntax_flags(%Face{} = face) do
    bold = if face.bold, do: 0x01, else: 0
    italic = if face.italic, do: 0x02, else: 0
    underline = if face.underline, do: 0x04, else: 0
    bold + italic + underline
  end

  @spec encode_markdown_style(Segment.style()) :: non_neg_integer()
  defp encode_markdown_style(:plain), do: 0
  defp encode_markdown_style(:bold), do: 1
  defp encode_markdown_style(:italic), do: 2
  defp encode_markdown_style(:bold_italic), do: 3
  defp encode_markdown_style(:code), do: 4
  defp encode_markdown_style(:code_block), do: 5
  defp encode_markdown_style({:code_content, _lang}), do: 6
  defp encode_markdown_style(:header1), do: 7
  defp encode_markdown_style(:header2), do: 8
  defp encode_markdown_style(:header3), do: 9
  defp encode_markdown_style(:blockquote), do: 10
  defp encode_markdown_style(:list_bullet), do: 11
  defp encode_markdown_style(:rule), do: 12
  defp encode_markdown_style(_), do: 0

  @spec encode_line_type(Line.line_type()) :: non_neg_integer()
  defp encode_line_type(:text), do: 0
  defp encode_line_type(:code), do: 1
  defp encode_line_type({:code_header, _lang}), do: 2
  defp encode_line_type(:header), do: 3
  defp encode_line_type(:blockquote), do: 4
  defp encode_line_type(:list_item), do: 5
  defp encode_line_type(:rule), do: 6
  defp encode_line_type(:empty), do: 7
  defp encode_line_type(_), do: 0
end
