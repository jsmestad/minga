defmodule Minga.Editor.Renderer.Regions do
  @moduledoc """
  Converts Layout rectangles into Zig renderer region commands.

  At the start of each frame, the renderer sends `define_region` commands
  for every active UI element. The Zig renderer uses these to clip draw
  commands and apply region-aware rendering. GUI frontends map regions to
  native views (NSView, GtkWidget, etc.).

  ## Region ID allocation

  Region IDs are assigned deterministically from the layout:

  * 0 — root (implicit, never defined)
  * 1 — file tree (if visible)
  * 2 — minibuffer
  * 3 — agent panel (if visible)
  * 100+ — editor windows (100 + window_id)
  * 200+ — window modelines (200 + window_id)

  This scheme avoids collisions and makes it easy to map a region ID
  back to the UI element it represents.
  """

  alias Minga.Editor.Layout
  alias Minga.Frontend.Protocol

  @region_file_tree 1
  @region_minibuffer 2
  @region_agent_panel 3
  @region_window_base 100
  @region_modeline_base 200

  @doc """
  Generates define_region commands for the current frame's layout.

  Returns a list of binary commands to send before any draw commands.
  Each region is defined with its role, absolute position, and z-order.
  """
  @spec define_regions(Layout.t()) :: [binary()]
  def define_regions(layout) do
    commands = []

    # File tree region
    commands =
      case layout.file_tree do
        {row, col, width, height} ->
          [
            Protocol.encode_define_region(
              @region_file_tree,
              0,
              :panel,
              row,
              col,
              width,
              height,
              0
            )
            | commands
          ]

        nil ->
          commands
      end

    # Minibuffer region (always present)
    {mr, mc, mw, mh} = layout.minibuffer

    commands = [
      Protocol.encode_define_region(@region_minibuffer, 0, :minibuffer, mr, mc, mw, mh, 0)
      | commands
    ]

    # Agent panel region
    commands =
      case layout.agent_panel do
        {row, col, width, height} ->
          [
            Protocol.encode_define_region(
              @region_agent_panel,
              0,
              :panel,
              row,
              col,
              width,
              height,
              0
            )
            | commands
          ]

        nil ->
          commands
      end

    # Editor window regions (content + modeline per window)
    window_commands =
      Enum.flat_map(layout.window_layouts, fn {win_id, wl} ->
        content_id = @region_window_base + win_id
        modeline_id = @region_modeline_base + win_id
        {cr, cc, cw, ch} = wl.content
        {mlr, mlc, mlw, mlh} = wl.modeline

        content_cmd = Protocol.encode_define_region(content_id, 0, :editor, cr, cc, cw, ch, 0)

        if mlh > 0 do
          modeline_cmd =
            Protocol.encode_define_region(modeline_id, 0, :modeline, mlr, mlc, mlw, mlh, 0)

          [content_cmd, modeline_cmd]
        else
          [content_cmd]
        end
      end)

    Enum.reverse(commands) ++ window_commands
  end

  @doc "Returns the region ID for a given editor window."
  @spec window_region_id(pos_integer()) :: pos_integer()
  def window_region_id(win_id), do: @region_window_base + win_id

  @doc "Returns the region ID for a given window's modeline."
  @spec modeline_region_id(pos_integer()) :: pos_integer()
  def modeline_region_id(win_id), do: @region_modeline_base + win_id
end
