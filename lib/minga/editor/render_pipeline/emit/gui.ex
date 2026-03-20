defmodule Minga.Editor.RenderPipeline.Emit.GUI do
  @moduledoc """
  GUI-specific emit logic for the Emit stage.

  Handles two responsibilities:

  1. **Frame filtering**: strips SwiftUI-owned chrome fields from the
     display list frame before it's converted to Metal cell-grid commands.
     Tab bar, file tree, agent panel, agentic view, status bar, and splash
     are handled natively by SwiftUI and should not appear in the cell grid.
     Gutter is also stripped from window frames since the GUI renders it
     natively.

  2. **Chrome synchronization**: sends structured chrome data (tab bar,
     file tree, which-key, completion, breadcrumb, status bar, picker,
     agent chat, theme) to the native GUI frontend via dedicated protocol
     opcodes. These are separate from the cell-grid rendering commands.

  Called from `Emit.emit/3` only when the frontend has GUI capabilities.
  """

  alias Minga.Agent.Session, as: AgentSession
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options
  alias Minga.Editor.DisplayList.Frame
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline.ContentHelpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.StatusBar.Data, as: StatusBarData
  alias Minga.Editor.Viewport
  alias Minga.Git.Tracker, as: GitTracker
  alias Minga.Picker
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  # ── Frame filtering ──────────────────────────────────────────────────────

  @doc """
  Filters a frame for GUI rendering by zeroing SwiftUI-owned chrome fields.

  The GUI frontend renders tab bar, file tree, agent panel, agentic view,
  status bar, and splash natively via SwiftUI. These fields are cleared so
  they don't appear in the Metal cell-grid output. Window frame gutters are
  also cleared since the GUI renders gutter natively.

  Overlays pass through intentionally: the Chrome stage already filters
  picker, which-key, and completion (empty in GUI mode). The remaining
  overlays (hover popup, signature help, float popups) are Metal-rendered
  and belong in the cell-grid output.
  """
  @spec filter_frame_for_gui(Frame.t()) :: Frame.t()
  def filter_frame_for_gui(frame) do
    %{
      frame
      | tab_bar: [],
        file_tree: [],
        agent_panel: [],
        agentic_view: [],
        status_bar: [],
        splash: nil,
        windows:
          Enum.map(frame.windows, fn wf ->
            # Buffer windows with semantic content get their text from the
            # 0x80 opcode, not draw_text. Strip lines + tilde_lines so
            # the cell-grid only carries overlays (hover, signature help).
            # Agent chat windows don't have semantic content and keep their draws.
            if wf.semantic != nil do
              %{wf | gutter: %{}, lines: %{}, tilde_lines: %{}}
            else
              %{wf | gutter: %{}}
            end
          end)
    }
  end

  # ── Chrome synchronization ──────────────────────────────────────────────

  @doc """
  Sends all GUI chrome data to the native frontend.

  Each chrome element is gathered from editor state, encoded to protocol
  binary, and sent to the port manager. The caller has already verified
  that the frontend has GUI capabilities.

  `status_bar_data` is pre-computed by the Chrome stage and passed through
  to avoid re-calling BufferServer for cursor/file info on the same frame.
  When nil (e.g. non-GUI fallback paths), it is computed here.
  """
  @spec sync_chrome(state(), StatusBarData.t() | nil) :: state()
  def sync_chrome(state, status_bar_data \\ nil) do
    send_gui_theme(state)
    send_gui_tab_bar(state)
    send_gui_file_tree(state)
    send_gui_which_key(state)
    send_gui_completion(state)
    send_gui_breadcrumb(state)
    send_gui_status_bar(state, status_bar_data || StatusBarData.from_state(state))
    send_gui_picker(state)
    send_gui_agent_chat(state)
    send_gui_gutter_separator(state)
    send_gui_cursorline(state)
    send_gui_gutter(state)
    send_gui_bottom_panel(state)
  end

  # ── Theme ──

  @spec send_gui_theme(state()) :: :ok
  defp send_gui_theme(state) do
    theme_name = state.theme.name

    if theme_name != Process.get(:last_gui_theme) do
      Process.put(:last_gui_theme, theme_name)
      PortManager.send_commands(state.port_manager, [ProtocolGUI.encode_gui_theme(state.theme)])
    end

    :ok
  end

  # ── Tab bar ──

  @spec send_gui_tab_bar(state()) :: :ok
  defp send_gui_tab_bar(%{tab_bar: %TabBar{} = tb} = state) do
    active_buf = active_window_buffer(state)
    cmd = ProtocolGUI.encode_gui_tab_bar(tb, active_buf)
    PortManager.send_commands(state.port_manager, [cmd])
    :ok
  end

  defp send_gui_tab_bar(%{tab_bar: nil}), do: :ok

  @spec active_window_buffer(state()) :: pid() | nil
  defp active_window_buffer(%{windows: %{active: win_id, map: map}}) do
    case Map.get(map, win_id) do
      %{buffer: buf} when is_pid(buf) -> buf
      _ -> nil
    end
  end

  # ── File tree ──

  @spec send_gui_file_tree(state()) :: :ok
  defp send_gui_file_tree(%{
         file_tree: %{tree: %Minga.FileTree{} = tree},
         port_manager: pm
       }) do
    cmd = ProtocolGUI.encode_gui_file_tree(tree)
    PortManager.send_commands(pm, [cmd])
    :ok
  end

  defp send_gui_file_tree(%{port_manager: pm}) do
    cmd = ProtocolGUI.encode_gui_file_tree(nil)
    PortManager.send_commands(pm, [cmd])
    :ok
  end

  # ── Which-key ──

  @spec send_gui_which_key(state()) :: :ok
  defp send_gui_which_key(%{whichkey: wk, port_manager: pm}) do
    cmd = ProtocolGUI.encode_gui_which_key(wk)
    PortManager.send_commands(pm, [cmd])
    :ok
  end

  # ── Completion ──

  @spec send_gui_completion(state()) :: :ok
  defp send_gui_completion(%{completion: comp, port_manager: pm} = state) do
    {cursor_row, cursor_col} = current_cursor_screen_pos(state)
    cmd = ProtocolGUI.encode_gui_completion(comp, cursor_row, cursor_col)
    PortManager.send_commands(pm, [cmd])
    :ok
  end

  @spec current_cursor_screen_pos(state()) :: {non_neg_integer(), non_neg_integer()}
  defp current_cursor_screen_pos(state) do
    layout = Layout.get(state)

    case Layout.active_window_layout(layout, state) do
      %{content: {row, col, _w, _h}} ->
        buf = state.buffers.active

        if buf do
          {line, column} = BufferServer.cursor(buf)
          vp = state.viewport
          {row + line - vp.top, col + column}
        else
          {row, col}
        end

      nil ->
        {0, 0}
    end
  end

  # ── Breadcrumb ──

  @spec send_gui_breadcrumb(state()) :: :ok
  defp send_gui_breadcrumb(%{port_manager: pm} = state) do
    file_path = active_buffer_path(state)

    root =
      case state.file_tree do
        %{tree: %{root: r}} -> r
        _ -> ""
      end

    cmd = ProtocolGUI.encode_gui_breadcrumb(file_path, root)
    PortManager.send_commands(pm, [cmd])
    :ok
  end

  @spec active_buffer_path(state()) :: String.t() | nil
  defp active_buffer_path(state) do
    case state.buffers.active do
      nil -> nil
      buf -> BufferServer.file_path(buf)
    end
  end

  # ── Status bar ──

  @spec send_gui_status_bar(state(), StatusBarData.t()) :: :ok
  defp send_gui_status_bar(%{port_manager: pm}, status_bar_data) do
    cmd = ProtocolGUI.encode_gui_status_bar(status_bar_data)
    PortManager.send_commands(pm, [cmd])
    :ok
  end

  # ── Picker ──

  @spec send_gui_picker(state()) :: :ok
  defp send_gui_picker(
         %{
           picker_ui: %{picker: picker, source: source, action_menu: action_menu},
           port_manager: pm
         } =
           state
       ) do
    case picker do
      nil ->
        picker_cmd = ProtocolGUI.encode_gui_picker(nil)
        preview_cmd = ProtocolGUI.encode_gui_picker_preview(nil)
        PortManager.send_commands(pm, [picker_cmd, preview_cmd])

      _ ->
        has_preview = source != nil and Picker.Source.preview?(source)

        preview_lines =
          if has_preview do
            build_picker_preview(state)
          else
            nil
          end

        # GUI gets up to 100 items so the native ScrollView can scroll.
        # The TUI path uses picker.max_visible (terminal rows).
        picker_cmd = ProtocolGUI.encode_gui_picker(picker, has_preview, action_menu, 100)
        preview_cmd = ProtocolGUI.encode_gui_picker_preview(preview_lines)
        PortManager.send_commands(pm, [picker_cmd, preview_cmd])
    end

    :ok
  end

  # Build preview content for the currently selected picker item.
  # Returns a list of lines, where each line is a list of {text, fg_color, bold} segments.
  @spec build_picker_preview(state()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp build_picker_preview(%{picker_ui: %{picker: picker}} = state) do
    case Minga.Picker.selected_item(picker) do
      nil ->
        nil

      %Minga.Picker.Item{id: id} ->
        build_preview_for_item(state, id)
    end
  end

  # Build preview lines for a file path item.
  # Uses syntax highlighting from an open buffer when available, falls back to plain text.
  @spec build_preview_for_item(state(), term()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp build_preview_for_item(state, id) when is_binary(id) do
    abs_path = resolve_preview_path(id)

    # Check if the file is already open in a buffer with highlights
    case find_buffer_for_path(state, abs_path) do
      {buf_pid, highlight} when highlight != nil ->
        build_highlighted_preview(buf_pid, highlight, state)

      _ ->
        read_file_preview(abs_path, state)
    end
  end

  # For buffer index items, use the buffer directly.
  defp build_preview_for_item(state, idx) when is_integer(idx) do
    case Enum.at(state.buffers.list, idx) do
      nil -> nil
      buf_pid -> preview_from_buffer(state, buf_pid)
    end
  end

  defp build_preview_for_item(_state, _id), do: nil

  @spec preview_from_buffer(state(), pid()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp preview_from_buffer(state, buf_pid) do
    case Map.get(state.highlight.highlights, buf_pid) do
      nil ->
        path = safe_file_path(buf_pid)
        if path, do: read_file_preview(path, state), else: nil

      highlight ->
        build_highlighted_preview(buf_pid, highlight, state)
    end
  end

  # Find a buffer PID for a given file path, along with its highlight state.
  @spec find_buffer_for_path(state(), String.t()) :: {pid(), Minga.Highlight.t() | nil} | nil
  defp find_buffer_for_path(state, abs_path) do
    Enum.find_value(state.buffers.list, fn buf_pid ->
      try do
        case BufferServer.file_path(buf_pid) do
          ^abs_path ->
            highlight = Map.get(state.highlight.highlights, buf_pid)
            {buf_pid, highlight}

          _ ->
            nil
        end
      catch
        :exit, _ -> nil
      end
    end)
  end

  @preview_max_lines 50

  # Build syntax-highlighted preview from a buffer with tree-sitter highlights.
  @spec build_highlighted_preview(pid(), Minga.Highlight.t(), state()) ::
          [[ProtocolGUI.preview_segment()]] | nil
  defp build_highlighted_preview(buf_pid, highlight, state) do
    content = BufferServer.content(buf_pid)
    lines = content |> String.split("\n") |> Enum.take(@preview_max_lines)
    default_fg = Map.get(state.theme, :fg, 0xCCCCCC)

    # Build {line_text, byte_offset} tuples for batch highlighting
    {line_tuples, _} =
      Enum.map_reduce(lines, 0, fn line, offset ->
        # +1 for the newline byte
        {{line, offset}, offset + byte_size(line) + 1}
      end)

    styled_lines = Minga.Highlight.styles_for_visible_lines(highlight, line_tuples)

    Enum.map(styled_lines, fn segments ->
      Enum.map(segments, fn {text, face} ->
        fg = face_to_rgb(face, default_fg)
        bold = face.bold || false
        {text, fg, bold}
      end)
    end)
  catch
    :exit, _ -> nil
  end

  # Convert a Face's fg color to a 24-bit RGB integer.
  @spec face_to_rgb(Minga.Face.t(), non_neg_integer()) :: non_neg_integer()
  defp face_to_rgb(%{fg: nil}, default), do: default
  defp face_to_rgb(%{fg: fg}, _default) when is_integer(fg), do: fg
  defp face_to_rgb(_, default), do: default

  @spec resolve_preview_path(String.t()) :: String.t()
  defp resolve_preview_path(path) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.join(Minga.Project.resolve_root(), path)
    end
  end

  # Read file from disk and return plain-text styled segments (no syntax highlighting).
  @spec read_file_preview(String.t(), state()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp read_file_preview(abs_path, state) do
    case File.read(abs_path) do
      {:ok, content} ->
        fg_color = Map.get(state.theme, :fg, 0xCCCCCC)

        content
        |> String.split("\n")
        |> Enum.take(@preview_max_lines)
        |> Enum.map(&[{&1, fg_color, false}])

      {:error, _} ->
        nil
    end
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(pid) do
    BufferServer.file_path(pid)
  catch
    :exit, _ -> nil
  end

  # ── Agent chat ──

  @spec send_gui_agent_chat(state()) :: :ok
  defp send_gui_agent_chat(%{port_manager: pm} = state) do
    data = build_agent_chat_data(state)

    if data.visible do
      Minga.Log.debug(:render, "[gui] sending agent chat: #{length(data.messages)} messages")
    end

    cmd = ProtocolGUI.encode_gui_agent_chat(data)
    PortManager.send_commands(pm, [cmd])
    :ok
  end

  @spec build_agent_chat_data(state()) :: map()
  defp build_agent_chat_data(state) do
    alias Minga.Editor.Window.Content

    active_window = Map.get(state.windows.map, state.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)
    session = state.agent.session

    if is_agent_chat && session do
      messages =
        try do
          AgentSession.messages(session)
        catch
          :exit, _ -> []
        end

      # Use cached styled runs for assistant messages when available.
      # This avoids recomputing tree-sitter/markdown styling per frame.
      styled_cache = state.agent_ui.panel.cached_styled_messages
      gui_messages = build_gui_messages(messages, styled_cache)

      prompt_text =
        case state.agent_ui.panel.prompt_buffer do
          nil -> ""
          buf -> BufferServer.content(buf) |> String.trim_trailing("\n")
        end

      pending = state.agent.pending_approval

      %{
        visible: true,
        messages: gui_messages,
        status: state.agent.status || :idle,
        model: state.agent_ui.panel.model_name,
        prompt: prompt_text,
        pending_approval: pending
      }
    else
      %{visible: false}
    end
  end

  # Builds the message list for GUI encoding. Replaces assistant messages
  # with {:styled_assistant, styled_lines} when cached styled runs are
  # available. Other message types pass through unchanged.
  #
  # Uses Enum.zip (O(n)) instead of Enum.at in a loop (O(n²)) since this
  # runs every render frame at 60fps.
  @spec build_gui_messages([term()], [term()] | nil) :: [term()]
  defp build_gui_messages(messages, nil), do: messages

  defp build_gui_messages(messages, styled_cache) when is_list(styled_cache) do
    # Pad the cache to match message length if needed (messages may have grown)
    padded = pad_cache(styled_cache, length(messages))

    Enum.zip(messages, padded)
    |> Enum.map(&maybe_style_message/1)
  end

  @spec maybe_style_message({term(), term()}) :: term()
  defp maybe_style_message({{:assistant, _text} = msg, nil}), do: msg

  defp maybe_style_message({{:assistant, _text}, styled_lines}),
    do: {:styled_assistant, styled_lines}

  defp maybe_style_message({msg, _cache_entry}), do: msg

  @spec pad_cache([term()], non_neg_integer()) :: [term()]
  defp pad_cache(cache, target_len) when length(cache) >= target_len, do: cache
  defp pad_cache(cache, target_len), do: cache ++ List.duplicate(nil, target_len - length(cache))

  # ── Gutter separator ──

  @spec send_gui_gutter_separator(state()) :: :ok
  defp send_gui_gutter_separator(state) do
    alias Minga.Config.Options

    show? = Options.get(:show_gutter_separator)
    active_window = Map.get(state.windows.map, state.windows.active)
    gutter_w = if active_window, do: active_window.last_gutter_w, else: 0

    # Only send separator when enabled, visible gutter (gutter_w > 0).
    # Use the theme's gutter separator color, falling back to gutter fg.
    # Theme colors are already 24-bit RGB integers.
    {col, color_rgb} =
      if show? and gutter_w > 0 do
        color = state.theme.gutter.separator_fg || state.theme.gutter.fg
        {gutter_w, color}
      else
        {0, 0}
      end

    cmd = ProtocolGUI.encode_gui_gutter_separator(max(col, 0), color_rgb)
    PortManager.send_commands(state.port_manager, [cmd])
    :ok
  end

  # ── Cursorline ──

  @spec send_gui_cursorline(state()) :: :ok
  defp send_gui_cursorline(state) do
    alias Minga.Config.Options

    active_window = Map.get(state.windows.map, state.windows.active)
    cursorline_enabled = Options.get(:cursorline)

    {row, bg_rgb} =
      if active_window && cursorline_enabled do
        # Compute screen row of cursor: content_rect row + (cursor_line - viewport_top)
        layout = Layout.get(state)

        case Layout.active_window_layout(layout, state) do
          %{content: {content_row, _col, _w, _h}} ->
            cursor_line = active_window.last_cursor_line || 0
            viewport_top = active_window.last_viewport_top || 0
            screen_row = content_row + cursor_line - viewport_top
            bg = state.theme.editor.cursorline_bg || 0
            {screen_row, bg}

          nil ->
            {0xFFFF, 0}
        end
      else
        {0xFFFF, 0}
      end

    cmd = ProtocolGUI.encode_gui_cursorline(row, bg_rgb)
    PortManager.send_commands(state.port_manager, [cmd])
    :ok
  end

  # ── Gutter ──

  @spec send_gui_gutter(state()) :: :ok
  defp send_gui_gutter(state) do
    alias Minga.Editor.Window.Content

    layout = Layout.get(state)

    cmds =
      Enum.flat_map(layout.window_layouts, fn {win_id, win_layout} ->
        window = Map.get(state.windows.map, win_id)

        # Skip agent chat windows (they don't have gutter)
        if window && is_pid(window.buffer) && !Content.agent_chat?(window.content) do
          is_active = win_id == state.windows.active
          gutter_data = build_window_gutter(state, window, win_id, win_layout, is_active)
          [ProtocolGUI.encode_gui_gutter(gutter_data)]
        else
          []
        end
      end)

    if cmds != [] do
      PortManager.send_commands(state.port_manager, cmds)
    end

    :ok
  end

  @spec build_window_gutter(
          state(),
          Minga.Editor.Window.t(),
          pos_integer(),
          Layout.window_layout(),
          boolean()
        ) :: ProtocolGUI.gutter_data()
  defp build_window_gutter(state, window, win_id, win_layout, is_active) do
    buf = window.buffer
    cursor_line = max(window.last_cursor_line, 0)
    viewport_top = max(window.last_viewport_top, 0)
    line_count = max(window.last_line_count, 0)

    {content_row, content_col, _content_w, content_height} = win_layout.content

    win_pos = %{
      window_id: win_id,
      content_row: content_row,
      content_col: content_col,
      content_height: content_height,
      is_active: is_active
    }

    # Guard against uninitialized window state (before first render)
    if line_count == 0 do
      Map.merge(win_pos, %{
        cursor_line: 0,
        line_number_style: :none,
        line_number_width: 0,
        sign_col_width: 0,
        entries: []
      })
    else
      build_gutter_entries(state, window, buf, win_pos, %{
        cursor_line: cursor_line,
        viewport_top: viewport_top,
        line_count: line_count
      })
    end
  end

  @spec build_gutter_entries(state(), Minga.Editor.Window.t(), pid(), map(), map()) ::
          ProtocolGUI.gutter_data()
  defp build_gutter_entries(state, window, buf, win_pos, params) do
    %{cursor_line: cursor_line, viewport_top: viewport_top, line_count: line_count} = params
    line_number_style = BufferServer.get_option(buf, :line_numbers)

    # Compute gutter geometry (same logic as Scroll stage)
    has_sign_column =
      GitTracker.tracked?(buf) or BufferServer.file_path(buf) != nil

    sign_col_width = if has_sign_column, do: 2, else: 0

    line_number_width =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    # Get signs for the buffer
    diag_signs = ContentHelpers.diagnostic_signs_for_window(state, window)
    git_signs = ContentHelpers.git_signs_for_window(state, window)

    # Build entries for each visible line
    entries =
      for row <- 0..(win_pos.content_height - 1) do
        buf_line = viewport_top + row

        sign_type =
          if buf_line < line_count do
            resolve_sign_type(buf_line, diag_signs, git_signs)
          else
            :none
          end

        %{buf_line: buf_line, display_type: :normal, sign_type: sign_type}
      end

    Map.merge(win_pos, %{
      cursor_line: cursor_line,
      line_number_style: line_number_style,
      line_number_width: line_number_width,
      sign_col_width: sign_col_width,
      entries: entries
    })
  end

  # Resolves the highest-priority sign for a buffer line.
  # Diagnostics take priority over git signs (same as Renderer.Gutter).
  @spec resolve_sign_type(
          non_neg_integer(),
          %{non_neg_integer() => atom()},
          %{non_neg_integer() => atom()}
        ) :: ProtocolGUI.sign_type()
  defp resolve_sign_type(buf_line, diag_signs, git_signs) do
    case Map.get(diag_signs, buf_line) do
      :error -> :diag_error
      :warning -> :diag_warning
      :info -> :diag_info
      :hint -> :diag_hint
      nil -> resolve_git_sign(buf_line, git_signs)
    end
  end

  @spec resolve_git_sign(non_neg_integer(), %{non_neg_integer() => atom()}) ::
          ProtocolGUI.sign_type()
  defp resolve_git_sign(buf_line, git_signs) do
    case Map.get(git_signs, buf_line) do
      :added -> :git_added
      :modified -> :git_modified
      :deleted -> :git_deleted
      _ -> :none
    end
  end

  # ── Bottom panel ──

  @spec send_gui_bottom_panel(state()) :: state()
  defp send_gui_bottom_panel(
         %{bottom_panel: panel, message_store: store, port_manager: pm} = state
       ) do
    {cmd, new_store} = ProtocolGUI.encode_gui_bottom_panel(panel, store)
    PortManager.send_commands(pm, [cmd])
    %{state | message_store: new_store}
  end
end
