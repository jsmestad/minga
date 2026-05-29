defmodule MingaEditor.RenderModel.UI.HoverPopupBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.HoverPopup
  alias Minga.RenderModel.UI.HoverPopup.Line
  alias Minga.RenderModel.UI.HoverPopup.Segment
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.HoverPopup, as: EditorHoverPopup

  @spec build(Context.t()) :: HoverPopup.t()
  def build(%Context{shell_state: %{hover_popup: popup}}), do: hover_popup_model(popup)
  def build(%Context{}), do: %HoverPopup{}

  @spec hover_popup_model(EditorHoverPopup.t() | nil) :: HoverPopup.t()
  defp hover_popup_model(nil), do: %HoverPopup{}
  defp hover_popup_model(%EditorHoverPopup{content_lines: []}), do: %HoverPopup{}

  defp hover_popup_model(%EditorHoverPopup{} = popup) do
    %HoverPopup{
      visible?: true,
      anchor_row: popup.anchor_row,
      anchor_col: popup.anchor_col,
      focused?: popup.focused,
      scroll_offset: popup.scroll_offset,
      content_lines: Enum.map(popup.content_lines, &line_model/1),
      open_action_name: open_action_name(popup.open_action)
    }
  end

  @spec line_model(tuple()) :: Line.t()
  defp line_model({segments, line_type}) do
    %Line{segments: Enum.map(segments, &segment_model/1), line_type: line_type(line_type)}
  end

  @spec segment_model(tuple()) :: Segment.t()
  defp segment_model({text, style}), do: %Segment{text: text, style: segment_style(style)}

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

  @spec open_action_name(EditorHoverPopup.open_action() | nil) :: String.t() | nil
  defp open_action_name(nil), do: nil
  defp open_action_name(action), do: EditorHoverPopup.open_action_name(action)
end
