defmodule MingaEditor.RenderModel.UI.HoverPopupBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.HoverPopup
  alias Minga.RenderModel.UI.HoverPopup.Line
  alias Minga.RenderModel.UI.HoverPopup.Segment
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.HoverPopup, as: EditorHoverPopup
  alias MingaEditor.HoverPopup.Presenter
  alias MingaEditor.HoverPopup.Terminal

  @spec build(Context.t()) :: HoverPopup.t()
  def build(%Context{intent: %{frame: %{shell_state: %{hover_popup: popup}} = frame}}),
    do: hover_popup_model(popup, frame)

  def build(%Context{}), do: %HoverPopup{}

  @spec hover_popup_model(EditorHoverPopup.t() | nil, MingaEditor.RenderPipeline.FrameIntent.t()) ::
          HoverPopup.t()
  defp hover_popup_model(nil, _frame), do: %HoverPopup{}
  defp hover_popup_model(%EditorHoverPopup{content_lines: []}, _frame), do: %HoverPopup{}

  defp hover_popup_model(%EditorHoverPopup{} = popup, frame) do
    {lines, offset} = presentation(popup, frame)

    %HoverPopup{
      visible?: true,
      anchor_row: popup.anchor_row,
      anchor_col: popup.anchor_col,
      focused?: popup.focused,
      scroll_offset: offset,
      content_lines: lines,
      offer_id: popup.offer_id,
      actions?: popup.code_source != nil,
      open_label: EditorHoverPopup.open_action_label(popup.open_action)
    }
  end

  @spec presentation(EditorHoverPopup.t(), MingaEditor.RenderPipeline.FrameIntent.t()) ::
          {[Line.t()], non_neg_integer()}
  defp presentation(
         %EditorHoverPopup{code_source: source} = popup,
         %{capabilities: %{frontend_type: :tui}, terminal_viewport: %{rows: rows, cols: cols}}
       )
       when source != nil do
    page =
      case Presenter.terminal_box(popup, {rows, cols}) do
        {_y, _x, _width, height} ->
          Terminal.page(popup.terminal, {popup.scroll_offset, popup.terminal_scroll_byte}, height)

        nil ->
          []
      end

    lines =
      Enum.map(page, fn {runs, type} ->
        segments =
          Enum.map(runs, fn
            {text, {:hover_link, id}} ->
              %Segment{text: text, style: {:link, id, id == popup.selected_link}}

            {text, style} ->
              %Segment{text: text, style: segment_style(style)}
          end)

        %Line{segments: segments, line_type: line_type(type)}
      end)

    {lines, 0}
  end

  defp presentation(popup, _frame), do: {line_models(popup), popup.scroll_offset}

  @spec line_models(EditorHoverPopup.t()) :: [Line.t()]
  defp line_models(popup) do
    last_link = tuple_size(popup.links) + 1

    {lines, _next} =
      Enum.map_reduce(EditorHoverPopup.display_lines(popup), 2, fn {segments, type}, id ->
        {segments, next} =
          Enum.map_reduce(segments, id, &segment_model(&1, &2, last_link, popup.selected_link))

        {%Line{segments: segments, line_type: line_type(type)}, next}
      end)

    lines
  end

  @spec segment_model(tuple(), pos_integer(), pos_integer(), pos_integer() | nil) ::
          {Segment.t(), pos_integer()}
  defp segment_model({text, {:link, _url}}, id, last_link, selected) when id <= last_link,
    do: {%Segment{text: text, style: {:link, id, id == selected}}, id + 1}

  defp segment_model({text, style}, id, _last_link, _selected),
    do: {%Segment{text: text, style: segment_style(style)}, id}

  @spec line_type(term()) :: Line.line_type()
  defp line_type(type)
       when type in [:text, :code, :header, :blockquote, :list_item, :rule, :empty],
       do: type

  defp line_type({:code_header, language}), do: {:code_header, normalize_language(language)}
  defp line_type(_type), do: :text

  @spec segment_style(term()) :: Segment.style()
  defp segment_style(style)
       when style in [
              :plain,
              :bold,
              :italic,
              :bold_italic,
              :code,
              :code_block,
              :header1,
              :header2,
              :header3,
              :blockquote,
              :list_bullet,
              :rule
            ],
       do: style

  defp segment_style({:code_content, language}), do: {:code_content, normalize_language(language)}
  defp segment_style({:syntax, %Minga.Core.Face{} = face}), do: {:syntax, face}
  defp segment_style(_style), do: :plain

  @spec normalize_language(term()) :: String.t() | nil
  defp normalize_language(language) when is_binary(language), do: language

  defp normalize_language(language)
       when is_atom(language) or is_integer(language) or is_float(language),
       do: to_string(language)

  defp normalize_language(language) when is_list(language) do
    to_string(language)
  rescue
    _e in [Protocol.UndefinedError, ArgumentError, UnicodeConversionError] -> nil
  end

  defp normalize_language(_language), do: nil
end
