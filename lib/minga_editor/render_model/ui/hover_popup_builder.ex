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
    %Line{segments: Enum.map(segments, &segment_model/1), line_type: line_type}
  end

  @spec segment_model(tuple()) :: Segment.t()
  defp segment_model({text, style}), do: %Segment{text: text, style: style}

  @spec open_action_name(EditorHoverPopup.open_action() | nil) :: String.t() | nil
  defp open_action_name(nil), do: nil
  defp open_action_name(action), do: EditorHoverPopup.open_action_name(action)
end
