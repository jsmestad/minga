defmodule Minga.Editor.RenderPipeline.Compose do
  @moduledoc """
  Stage 6: Compose.

  Merges content `WindowFrame` structs and `Chrome` into a final `Frame`.
  Injects modeline draws into each window frame, resolves cursor position
  and shape from the priority chain (picker > minibuffer > agent > window > fallback).
  """

  alias Minga.Editor.DisplayList.{Cursor, Frame, WindowFrame}
  alias Minga.Editor.Layout
  alias Minga.Editor.Modeline
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.ComposeHelpers
  alias Minga.Editor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Merges content WindowFrames and Chrome into a `Frame` struct.

  Injects modeline draws into each WindowFrame, resolves cursor
  position and shape, and assembles the final frame.
  """
  @spec compose_windows(
          [WindowFrame.t()],
          Chrome.t(),
          Cursor.t() | nil,
          state()
        ) :: Frame.t()
  def compose_windows(window_frames, chrome, cursor_info, state) do
    layout = Layout.get(state)

    # Resolve cursor from window frames, overlays, and fallbacks.
    # Priority (highest first): picker overlay → agent panel → active WindowFrame → fallback.
    {minibuffer_row, _, _, _} = layout.minibuffer
    picker_cursor = ComposeHelpers.find_picker_cursor(chrome.overlays)

    # Build the final cursor. Priority (highest first):
    # picker overlay → minibuffer (command/search/eval) → agent panel →
    # active WindowFrame → fallback.
    #
    # Minibuffer modes must override the window frame cursor because the
    # window frame still carries the buffer cursor from before entering
    # command/search/eval mode.
    active_wf_cursor = Enum.find_value(window_frames, fn wf -> wf.cursor end)
    minibuffer_result = ComposeHelpers.resolve_cursor(state, cursor_info, minibuffer_row)
    minibuffer_mode? = state.vim.mode in [:command, :search, :eval]

    cursor =
      resolve_frame_cursor(
        picker_cursor,
        if(minibuffer_mode?, do: minibuffer_result),
        ComposeHelpers.agent_cursor_from_layout(state, layout),
        active_wf_cursor,
        minibuffer_result,
        Modeline.cursor_shape(state.vim)
      )

    %Frame{
      cursor: cursor,
      tab_bar: chrome.tab_bar,
      windows: window_frames,
      file_tree: chrome.file_tree,
      separators: chrome.separators,
      status_bar: chrome.status_bar_draws,
      agent_panel: chrome.agent_panel,
      minibuffer: chrome.minibuffer,
      overlays: chrome.overlays,
      regions: chrome.regions
    }
  end

  # Resolves the final frame cursor from the priority chain.
  # Each argument is checked in order; the first non-nil wins.
  # Priority: picker → minibuffer → agent panel → window frame → fallback.
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
