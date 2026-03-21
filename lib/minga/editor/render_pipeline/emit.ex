defmodule Minga.Editor.RenderPipeline.Emit do
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

  alias Minga.Config.Options
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.Frame
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.Emit.GUI, as: EmitGUI
  alias Minga.Editor.RenderPipeline.Emit.TUI, as: EmitTUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Title
  alias Minga.Port.Capabilities
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol.GUIWindowContent
  alias Minga.Telemetry

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Converts the frame to protocol command binaries and sends them to
  the frontend port. Dispatches to `Emit.TUI` or `Emit.GUI` based on
  frontend capabilities.

  Also sends title and window background color when they change
  (side-channel writes).
  """
  @spec emit(Frame.t(), state(), Chrome.t() | nil) :: state()
  def emit(frame, state, chrome \\ nil) do
    # Make the font registry available for font_family → font_id resolution
    # during draws_to_commands. Initialize only on first frame; subsequent
    # frames reuse the accumulated registry so IDs are stable and register_font
    # commands are only sent once per font family.
    if Process.get(:emit_font_registry) == nil do
      Process.put(:emit_font_registry, state.font_registry)
    end

    gui? = Capabilities.gui?(state.capabilities)

    if gui? do
      emit_gui(frame, state, chrome)
    else
      emit_tui(frame, state)
    end
  end

  # GUI emit: bundles all Metal-critical commands (frame content, window
  # content, gutter, cursorline, gutter separator) into a single port
  # message so they arrive atomically in one DispatchQueue.main.async block.
  # SwiftUI chrome (tab bar, file tree, status bar, etc.) is sent separately
  # since it doesn't affect the Metal render pass.
  @spec emit_gui(Frame.t(), state(), Chrome.t() | nil) :: state()
  defp emit_gui(frame, state, chrome) do
    # Frame commands WITHOUT batch_end (we append it after Metal-critical chrome)
    frame_cmds =
      frame
      |> EmitGUI.filter_frame_for_gui()
      |> DisplayList.to_commands(batch_end: false)

    # Semantic window content (0x80 opcode)
    window_content_cmds = build_gui_window_content_commands(frame)

    # Metal-critical chrome: gutter, cursorline, gutter separator
    metal_chrome_cmds = EmitGUI.build_metal_commands(state)

    # Bundle everything into one atomic port message, with batch_end last
    all_metal =
      frame_cmds ++
        window_content_cmds ++
        metal_chrome_cmds ++
        [Minga.Port.Protocol.encode_batch_end()]

    update_tracking(state)

    byte_count = IO.iodata_length(all_metal)

    Telemetry.span([:minga, :port, :emit], %{byte_count: byte_count}, fn ->
      PortManager.send_commands(state.port_manager, all_metal)
      send_title(state)
      send_window_bg(state)

      # SwiftUI chrome: separate messages, safe (no Metal impact)
      status_bar_data = chrome && chrome.status_bar_data
      EmitGUI.sync_swiftui_chrome(state, status_bar_data)
    end)
  end

  # TUI emit: single send_commands call (already atomic).
  @spec emit_tui(Frame.t(), state()) :: state()
  defp emit_tui(frame, state) do
    commands = EmitTUI.build_commands(frame, state)
    update_tracking(state)
    byte_count = IO.iodata_length(commands)

    Telemetry.span([:minga, :port, :emit], %{byte_count: byte_count}, fn ->
      PortManager.send_commands(state.port_manager, commands)
      send_title(state)
      send_window_bg(state)
      state
    end)
  end

  # ── Tracking state (shared) ──────────────────────────────────────────────

  @spec update_tracking(state()) :: :ok
  defp update_tracking(state) do
    layout = Layout.get(state)

    tops =
      Map.new(layout.window_layouts, fn {win_id, _wl} ->
        window = Map.get(state.windows.map, win_id)

        if window do
          {win_id, window.last_viewport_top}
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
        window = Map.get(state.windows.map, win_id)

        if window do
          {win_id, window.last_gutter_w}
        else
          {win_id, -1}
        end
      end)

    buf_versions =
      Map.new(layout.window_layouts, fn {win_id, _wl} ->
        window = Map.get(state.windows.map, win_id)

        if window do
          {win_id, window.last_buf_version}
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

  @spec send_title(state()) :: :ok
  defp send_title(state) do
    title =
      if Capabilities.gui?(state.capabilities) do
        Title.format_gui(state)
      else
        format = Options.get(:title_format) |> to_string()
        title = Title.format(state, format)

        # Prepend [!] when any agent tab needs attention (TUI only).
        if state.tab_bar && TabBar.any_attention?(state.tab_bar) do
          "[!] " <> title
        else
          title
        end
      end

    if title != Process.get(:last_title) do
      Process.put(:last_title, title)
      PortManager.send_commands([Minga.Port.Protocol.encode_set_title(title)])
    end

    :ok
  end

  @spec send_window_bg(state()) :: :ok
  defp send_window_bg(state) do
    bg = state.theme.editor.bg

    if bg != Process.get(:last_window_bg) do
      Process.put(:last_window_bg, bg)
      PortManager.send_commands([Minga.Port.Protocol.encode_set_window_bg(bg)])
    end

    :ok
  end
end
