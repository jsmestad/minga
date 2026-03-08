defmodule Minga.Editor.Renderer do
  @moduledoc """
  Buffer and UI rendering for the editor.

  This module is the public API for rendering. It delegates to
  `RenderPipeline`, which decomposes rendering into seven named stages:
  Invalidation, Layout, Scroll, Content, Chrome, Compose, Emit.

  Sub-modules handle focused rendering concerns:

  * `Renderer.Gutter`          — line number rendering
  * `Renderer.Line`            — line content and selection rendering
  * `Renderer.SearchHighlight` — search/substitute highlight overlays
  * `Renderer.Minibuffer`      — command/search/status line
  * `Renderer.Caps`            — capability-aware rendering helpers
  * `Renderer.Regions`         — region definition commands
  * `DisplayList`              — frame assembly and protocol conversion
  """

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.Frame
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.State, as: EditorState
  alias Minga.Port.Manager, as: PortManager

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc """
  Represents the bounds of a visual selection for rendering.

  * `nil` — no active selection
  * `{:char, start_pos, end_pos}` — characterwise selection
  * `{:line, start_line, end_line}` — linewise selection
  """
  @type visual_selection ::
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()}

  @doc "Renders the no-buffer splash screen."
  @spec render(state()) :: :ok
  def render(%{buffers: %{active: nil}} = state) do
    splash_draws = [
      DisplayList.draw(0, 0, "Minga v#{Minga.version()} — No file open"),
      DisplayList.draw(1, 0, "Use: mix minga <filename>")
    ]

    frame = %Frame{
      cursor: {0, 0},
      cursor_shape: :block,
      splash: splash_draws
    }

    commands = DisplayList.to_commands(frame)
    PortManager.send_commands(state.port_manager, commands)
  end

  def render(state) do
    RenderPipeline.run(state)
  end
end
