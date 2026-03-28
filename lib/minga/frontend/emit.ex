defmodule Minga.Frontend.Emit do
  @moduledoc """
  Stage 7: Emit.

  Dispatches to `Emit.TUI` or `Emit.GUI` based on frontend capabilities,
  then handles shared concerns (viewport tracking, title, window background).

  TUI: converts the composed `Frame` into protocol command binaries using
  scroll region optimization when possible (see `Emit.TUI`).

  GUI: filters SwiftUI-owned chrome from the frame, converts to Metal
  cell-grid commands, then syncs structured chrome data via dedicated
  protocol opcodes (see `Emit.GUI`).
  """

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.Frame
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Frontend.Emit.Context
  alias Minga.Frontend.Emit.GUI, as: EmitGUI
  alias Minga.Frontend.Emit.TUI, as: EmitTUI
  alias Minga.Frontend.Protocol.GUIWindowContent
  alias Minga.Telemetry

  @typedoc "Emit context containing only the data emit needs."
  @type ctx :: Context.t()

  @doc """
  Converts the frame to protocol command binaries and sends them to
  the frontend port. Dispatches to `Emit.TUI` or `Emit.GUI` based on
  frontend capabilities.

  Also sends title and window background color when they change
  (side-channel writes).
  """
  @spec emit(Frame.t(), ctx(), Chrome.t() | nil) :: :ok
  def emit(frame, ctx, chrome \\ nil) do
    # Make the font registry available for font_family → font_id resolution
    # during draws_to_commands. Initialize only on first frame; subsequent
    # frames reuse the accumulated registry so IDs are stable and register_font
    # commands are only sent once per font family.
    if Process.get(:emit_font_registry) == nil do
      Process.put(:emit_font_registry, ctx.font_registry)
    end

    gui? = Minga.Frontend.gui?(ctx.capabilities)

    if gui? do
      emit_gui(frame, ctx, chrome)
    else
      emit_tui(frame, ctx)
    end
  end

  # GUI emit: bundles all Metal-critical commands (frame content, window
  # content, gutter, cursorline, gutter separator) into a single port
  # message so they arrive atomically in one DispatchQueue.main.async block.
  # SwiftUI chrome (tab bar, file tree, status bar, etc.) is sent separately
  # since it doesn't affect the Metal render pass.
  @spec emit_gui(Frame.t(), ctx(), Chrome.t() | nil) :: :ok
  defp emit_gui(frame, ctx, chrome) do
    # Frame commands WITHOUT batch_end (we append it after Metal-critical chrome)
    frame_cmds =
      frame
      |> EmitGUI.filter_frame_for_gui()
      |> DisplayList.to_commands(batch_end: false)

    # Semantic window content (0x80 opcode)
    window_content_cmds = build_gui_window_content_commands(frame)

    # Metal-critical chrome: gutter, cursorline, gutter separator
    metal_chrome_cmds = EmitGUI.build_metal_commands(ctx)

    # Bundle everything into one atomic port message, with batch_end last
    all_metal =
      frame_cmds ++
        window_content_cmds ++
        metal_chrome_cmds ++
        [Minga.Frontend.Protocol.encode_batch_end()]

    update_tracking(ctx)

    byte_count = IO.iodata_length(all_metal)

    Telemetry.span([:minga, :port, :emit], %{byte_count: byte_count}, fn ->
      Minga.Frontend.send_commands(ctx.port_manager, all_metal)
      send_title(ctx)
      send_window_bg(ctx)

      # SwiftUI chrome: separate messages, safe (no Metal impact)
      status_bar_data = chrome && chrome.status_bar_data
      minibuffer_data = chrome && chrome.minibuffer_data
      EmitGUI.sync_swiftui_chrome(ctx, status_bar_data, minibuffer_data)
      :ok
    end)
  end

  # TUI emit: single send_commands call (already atomic).
  @spec emit_tui(Frame.t(), ctx()) :: :ok
  defp emit_tui(frame, ctx) do
    commands = EmitTUI.build_commands(frame, ctx)
    update_tracking(ctx)
    byte_count = IO.iodata_length(commands)

    Telemetry.span([:minga, :port, :emit], %{byte_count: byte_count}, fn ->
      Minga.Frontend.send_commands(ctx.port_manager, commands)
      send_title(ctx)
      send_window_bg(ctx)
      :ok
    end)
  end

  # ── Tracking state (shared) ──────────────────────────────────────────────

  @spec update_tracking(ctx()) :: :ok
  defp update_tracking(ctx) do
    layout = ctx.layout

    tops =
      Map.new(layout.window_layouts, fn {win_id, _wl} ->
        window = Map.get(ctx.windows.map, win_id)

        if window do
          {win_id, window.render_cache.last_viewport_top}
        else
          {win_id, -1}
        end
      end)

    rects =
      Map.new(layout.window_layouts, fn {win_id, wl} ->
        {win_id, wl.content}
      end)

    gutter_ws =
      Map.new(layout.window_layouts, fn {win_id, _wl} ->
        window = Map.get(ctx.windows.map, win_id)

        if window do
          {win_id, window.render_cache.last_gutter_w}
        else
          {win_id, -1}
        end
      end)

    buf_versions =
      Map.new(layout.window_layouts, fn {win_id, _wl} ->
        window = Map.get(ctx.windows.map, win_id)

        if window do
          {win_id, window.render_cache.last_buf_version}
        else
          {win_id, -1}
        end
      end)

    Process.put(:emit_prev_viewport_tops, tops)
    Process.put(:emit_prev_content_rects, rects)
    Process.put(:emit_prev_gutter_ws, gutter_ws)
    Process.put(:emit_prev_buf_versions, buf_versions)
    :ok
  end

  # ── GUI window content (0x80) ────────────────────────────────────────────

  # Builds gui_window_content commands for each buffer window that has
  # a semantic struct attached. Returns encoded commands for bundling
  # into the atomic Metal frame.
  @spec build_gui_window_content_commands(Frame.t()) :: [binary()]
  defp build_gui_window_content_commands(frame) do
    Enum.flat_map(frame.windows, fn
      %DisplayList.WindowFrame{semantic: nil} -> []
      %DisplayList.WindowFrame{semantic: semantic} -> [GUIWindowContent.encode(semantic)]
    end)
  end

  # ── Side-channel writes (shared) ─────────────────────────────────────────

  @spec send_title(ctx()) :: :ok
  defp send_title(ctx) do
    title = ctx.title

    if title != Process.get(:last_title) do
      Process.put(:last_title, title)
      Minga.Frontend.set_title(title)
    end

    :ok
  end

  @spec send_window_bg(ctx()) :: :ok
  defp send_window_bg(ctx) do
    bg = ctx.theme.editor.bg

    if bg != Process.get(:last_window_bg) do
      Process.put(:last_window_bg, bg)
      Minga.Frontend.set_window_bg(bg)
    end

    :ok
  end
end
