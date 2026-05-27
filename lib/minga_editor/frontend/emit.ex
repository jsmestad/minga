defmodule MingaEditor.Frontend.Emit do
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

  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.Frame
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Emit.GUI, as: EmitGUI
  alias MingaEditor.Frontend.Emit.TUI, as: EmitTUI
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUIWindowContent
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.UI.FontRegistry
  alias Minga.Telemetry

  @typedoc "Emit context containing only the data emit needs."
  @type ctx :: Context.t()

  @doc """
  Converts the frame to protocol command binaries and sends them to
  the frontend port. Dispatches to `Emit.TUI` or `Emit.GUI` based on
  frontend capabilities.

  Also sends title and window background color when they change
  (side-channel writes). Returns updated caches and the renderer-owned font
  registry for write-back to the Renderer process.
  """
  @spec emit(Frame.t(), ctx(), Chrome.t() | nil, Caches.t()) :: {Caches.t(), FontRegistry.t()}
  def emit(frame, ctx, chrome \\ nil, caches \\ %Caches{}) do
    FontRegistry.with_process_registry(ctx.font_registry, fn ->
      gui? = MingaEditor.Frontend.gui?(ctx.capabilities)

      caches =
        if gui? do
          emit_gui(frame, ctx, chrome, caches)
        else
          emit_tui(frame, ctx, caches)
        end

      {caches, FontRegistry.current_process_registry(ctx.font_registry)}
    end)
  end

  # GUI emit: bundles all Metal-critical commands (frame content, window
  # content, gutter, cursorline, gutter separator) into a single port
  # message so they arrive atomically in one DispatchQueue.main.async block.
  # SwiftUI chrome (tab bar, file tree, status bar, etc.) is sent separately
  # since it doesn't affect the Metal render pass.
  @spec emit_gui(Frame.t(), ctx(), Chrome.t() | nil, Caches.t()) :: Caches.t()
  defp emit_gui(frame, ctx, chrome, caches) do
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
        [Protocol.encode_batch_end()]

    all_metal = flush_font_registration_commands() ++ all_metal
    caches = update_tracking(ctx, caches)

    byte_count = IO.iodata_length(all_metal)

    Telemetry.span([:minga, :port, :emit], %{byte_count: byte_count}, fn ->
      MingaEditor.Frontend.send_commands(ctx.port_manager, all_metal)
      caches = send_title(ctx, caches)
      caches = send_window_bg(ctx, caches)

      # Core adapter: migrated UI components
      status_bar_data = chrome && chrome.status_bar_data
      minibuffer_data = chrome && chrome.minibuffer_data

      {ui_model, ctx} =
        MingaEditor.RenderModel.UI.Builder.build_ui(ctx, status_bar_data, minibuffer_data)

      {adapter_cmds, adapter_caches} =
        Minga.Frontend.Adapter.GUI.encode_ui(ui_model, caches.adapter_gui_caches)

      caches = %{caches | adapter_gui_caches: adapter_caches}

      if adapter_cmds != [] do
        MingaEditor.Frontend.send_commands(ctx.port_manager, adapter_cmds)
      end

      caches
    end)
  end

  # TUI emit: single send_commands call (already atomic).
  @spec emit_tui(Frame.t(), ctx(), Caches.t()) :: Caches.t()
  defp emit_tui(frame, ctx, caches) do
    commands = EmitTUI.build_commands(frame, ctx, caches)
    commands = flush_font_registration_commands() ++ commands
    caches = update_tracking(ctx, caches)
    byte_count = IO.iodata_length(commands)

    Telemetry.span([:minga, :port, :emit], %{byte_count: byte_count}, fn ->
      MingaEditor.Frontend.send_commands(ctx.port_manager, commands)
      caches = send_title(ctx, caches)
      caches = send_window_bg(ctx, caches)
      caches
    end)
  end

  # ── Font registry context (shared) ───────────────────────────────────────

  @spec flush_font_registration_commands() :: [binary()]
  defp flush_font_registration_commands do
    registry = FontRegistry.current_process_registry(FontRegistry.new())

    commands =
      registry
      |> FontRegistry.pending_registrations()
      |> Enum.map(fn {font_id, family} -> Protocol.encode_register_font(font_id, family) end)

    registry
    |> FontRegistry.mark_registered()
    |> FontRegistry.put_process_registry()

    commands
  end

  # ── Tracking state (shared) ──────────────────────────────────────────────

  @spec update_tracking(ctx(), Caches.t()) :: Caches.t()
  defp update_tracking(ctx, caches) do
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

    editing_mode = if ctx.editing, do: ctx.editing.mode, else: nil

    %{
      caches
      | emit_prev_viewport_tops: tops,
        emit_prev_content_rects: rects,
        emit_prev_gutter_ws: gutter_ws,
        emit_prev_buf_versions: buf_versions,
        emit_prev_editing_mode: editing_mode
    }
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

  @spec send_title(ctx(), Caches.t()) :: Caches.t()
  defp send_title(ctx, caches) do
    title = ctx.title

    if title != caches.last_title do
      MingaEditor.Frontend.set_title(title)
      %{caches | last_title: title}
    else
      caches
    end
  end

  @spec send_window_bg(ctx(), Caches.t()) :: Caches.t()
  defp send_window_bg(ctx, caches) do
    bg = ctx.theme.editor.bg

    if bg != caches.last_window_bg do
      MingaEditor.Frontend.set_window_bg(bg)
      %{caches | last_window_bg: bg}
    else
      caches
    end
  end
end
