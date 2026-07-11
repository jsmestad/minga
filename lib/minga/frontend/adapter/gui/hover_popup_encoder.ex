defmodule Minga.Frontend.Adapter.GUI.HoverPopupEncoder do
  @moduledoc false

  alias Minga.Core.Face
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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

    writer =
      :gui_hover_popup
      |> Writer.new()
      |> Writer.append(<<@op_gui_hover_popup, 1::8>>)
      |> Writer.uint16(:anchor_row, model.anchor_row)
      |> Writer.uint16(:anchor_col, model.anchor_col)
      |> Writer.uint8(:focused, focused_byte)
      |> Writer.uint16(:scroll_offset, model.scroll_offset)
      |> Writer.uint16(:line_count, Enum.count(model.content_lines))

    hover =
      model.content_lines
      |> Enum.reduce(writer, &encode_line/2)
      |> Writer.finish()

    IO.iodata_to_binary([hover, encode_hover_action(model.open_action_name)])
  end

  @spec fingerprint(HoverPopup.t()) :: term()
  defp fingerprint(%HoverPopup{visible?: false}), do: :hidden

  defp fingerprint(%HoverPopup{} = model) do
    {model.visible?, model.anchor_row, model.anchor_col, model.focused?, model.scroll_offset,
     model.content_lines, model.open_action_name}
  end

  @spec encode_line(Line.t(), Writer.t()) :: Writer.t()
  defp encode_line(%Line{} = line, %Writer{} = writer) do
    writer =
      writer
      |> Writer.uint8(:line_type, encode_line_type(line.line_type))
      |> Writer.uint16(:segment_count, Enum.count(line.segments))

    Enum.reduce(line.segments, writer, &encode_markdown_segment/2)
  end

  @spec encode_hover_action(String.t() | nil) :: binary()
  defp encode_hover_action(nil), do: <<@op_gui_hover_action, 1::16, 0::8>>

  defp encode_hover_action(action_name) do
    payload =
      :gui_hover_action
      |> Writer.new()
      |> Writer.append(<<1::8>>)
      |> Writer.string16(:action_name, action_name)
      |> Writer.finish()

    :gui_hover_action
    |> Writer.new()
    |> Writer.append(<<@op_gui_hover_action>>)
    |> Writer.payload16(:payload, payload)
    |> Writer.finish()
  end

  @spec encode_markdown_segment(Segment.t(), Writer.t()) :: Writer.t()
  defp encode_markdown_segment(
         %Segment{text: text, style: {:syntax, %Face{} = face}},
         %Writer{} = writer
       ) do
    writer
    |> Writer.append(<<13::8>>)
    |> Writer.rgb24(:syntax_fg, face.fg || @syntax_fallback_fg)
    |> Writer.uint8(:syntax_flags, encode_syntax_flags(face))
    |> Writer.string16(:segment_text, text)
  end

  defp encode_markdown_segment(%Segment{} = segment, %Writer{} = writer) do
    writer
    |> Writer.uint8(:markdown_style, encode_markdown_style(segment.style))
    |> Writer.string16(:segment_text, segment.text)
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
