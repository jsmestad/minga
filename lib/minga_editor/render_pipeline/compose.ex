defmodule MingaEditor.RenderPipeline.Compose do
  @moduledoc """
  Stage 6: Compose.

  Flattens the per-window `WindowContent` models into the frame's window list
  and resolves the final cursor position and shape from the priority chain
  (picker > minibuffer > agent > window > fallback). The modeline is carried by
  the semantic chrome (`gui_status_bar` 0x76), so no modeline draws are injected
  here. The result is a `ComposedFrame` the Emit stage encodes.
  """

  alias Minga.RenderModel.Cursor
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.ComposeHelpers
  alias MingaEditor.RenderPipeline.ComposedFrame
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.WindowContent

  @typedoc "Render pipeline input."
  @type state :: Input.t()

  @doc """
  Flattens window content models and resolves the final cursor into a
  `ComposedFrame`.
  """
  @spec compose_windows(
          [WindowContent.t()],
          Chrome.t(),
          Cursor.t() | nil,
          state()
        ) :: ComposedFrame.t()
  def compose_windows(window_contents, chrome, cursor_info, state) do
    layout = Layout.get(state)

    # Resolve cursor from window contents, overlays, and fallbacks.
    # Priority (highest first): picker overlay → minibuffer → agent panel →
    # active window cursor → fallback.
    {minibuffer_row, _, _, _} = layout.minibuffer
    picker_cursor = ComposeHelpers.find_picker_cursor(chrome.overlays)

    # Minibuffer modes must override the window cursor because the window still
    # carries the buffer cursor from before entering command/search/eval mode.
    active_window_cursor = Enum.find_value(window_contents, fn wc -> wc.cursor end)
    minibuffer_result = ComposeHelpers.resolve_cursor(state, cursor_info, minibuffer_row)
    minibuffer_mode? = Minga.Editing.minibuffer_mode?(state)

    cursor =
      resolve_frame_cursor(
        picker_cursor,
        if(minibuffer_mode?, do: minibuffer_result),
        ComposeHelpers.agent_cursor_from_layout(state, layout),
        active_window_cursor,
        minibuffer_result,
        Minga.Editing.cursor_shape(state)
      )

    ComposedFrame.new(window_models(window_contents), cursor)
  end

  @spec window_models([WindowContent.t()]) :: [Minga.RenderModel.Window.t()]
  defp window_models(window_contents) do
    Enum.flat_map(window_contents, fn %WindowContent{models: models} -> models end)
  end

  # Resolves the final frame cursor from the priority chain.
  # Each argument is checked in order; the first non-nil wins.
  # Priority: picker → minibuffer → agent panel → window → fallback.
  @spec resolve_frame_cursor(
          {non_neg_integer(), non_neg_integer()} | nil,
          {non_neg_integer(), non_neg_integer()} | nil,
          Cursor.t() | nil,
          Cursor.t() | nil,
          {non_neg_integer(), non_neg_integer()},
          Cursor.shape()
        ) :: Cursor.t()
  defp resolve_frame_cursor({row, col}, _, _, _, _, _), do: Cursor.new(row, col, :beam)
  defp resolve_frame_cursor(nil, {row, col}, _, _, _, _), do: Cursor.new(row, col, :beam)
  defp resolve_frame_cursor(nil, nil, %Cursor{} = c, _, _, _), do: c
  defp resolve_frame_cursor(nil, nil, nil, %Cursor{} = c, _, _), do: c

  defp resolve_frame_cursor(nil, nil, nil, nil, {row, col}, shape) do
    Cursor.new(row, col, shape)
  end
end
