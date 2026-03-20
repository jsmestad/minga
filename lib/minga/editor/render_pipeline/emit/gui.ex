defmodule Minga.Editor.RenderPipeline.Emit.GUI do
  @moduledoc """
  GUI chrome synchronization for the Emit stage.

  Sends structured chrome data (tab bar, file tree, which-key, completion,
  breadcrumb, status bar, picker, agent chat, theme) to the native GUI
  frontend. These are separate from the TUI cell-grid rendering commands
  and from the frame-to-commands conversion in `Emit`.

  Called from `Emit.emit/2` only when the frontend has GUI capabilities.
  Each function independently gathers state, encodes to protocol binary,
  and sends to the port manager.
  """

  alias Minga.Agent.Session, as: AgentSession
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline.ContentHelpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.StatusBar.Data, as: StatusBarData
  alias Minga.Editor.Viewport
  alias Minga.Git.Tracker, as: GitTracker
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

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
  defp send_gui_picker(%{picker_ui: %{picker: picker}, port_manager: pm}) do
    cmd = ProtocolGUI.encode_gui_picker(picker)
    PortManager.send_commands(pm, [cmd])
    :ok
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

<<<<<<< HEAD
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
          gutter_data = build_window_gutter(state, window, win_layout, is_active)
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
          Layout.window_layout(),
          boolean()
        ) :: ProtocolGUI.gutter_data()
  defp build_window_gutter(state, window, win_layout, is_active) do
    buf = window.buffer
    cursor_line = max(window.last_cursor_line, 0)
    viewport_top = max(window.last_viewport_top, 0)
    line_count = max(window.last_line_count, 0)

    {content_row, content_col, _content_w, content_height} = win_layout.content

    win_pos = %{
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
