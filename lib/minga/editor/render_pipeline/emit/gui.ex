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
  alias Minga.Diagnostics
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.TabBar
  alias Minga.Filetype
  alias Minga.Git
  alias Minga.LSP.SyncServer, as: LspSyncServer
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Sends all GUI chrome data to the native frontend.

  Each chrome element is gathered from editor state, encoded to protocol
  binary, and sent to the port manager. The caller has already verified
  that the frontend has GUI capabilities.
  """
  @spec sync_chrome(state()) :: :ok
  def sync_chrome(state) do
    send_gui_theme(state)
    send_gui_tab_bar(state)
    send_gui_file_tree(state)
    send_gui_which_key(state)
    send_gui_completion(state)
    send_gui_breadcrumb(state)
    send_gui_status_bar(state)
    send_gui_picker(state)
    send_gui_agent_chat(state)
    send_gui_gutter_separator(state)
    :ok
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

  @spec send_gui_status_bar(state()) :: :ok
  defp send_gui_status_bar(%{port_manager: pm} = state) do
    data = build_status_bar_data(state)
    cmd = ProtocolGUI.encode_gui_status_bar(data)
    PortManager.send_commands(pm, [cmd])
    :ok
  end

  @spec build_status_bar_data(state()) :: map()
  defp build_status_bar_data(state) do
    buf = state.buffers.active
    {line, col} = if buf, do: BufferServer.cursor(buf), else: {1, 0}
    line_count = if buf, do: BufferServer.line_count(buf), else: 1
    file_name = if buf, do: BufferServer.file_path(buf) || "", else: ""

    diagnostic_counts = diagnostic_counts_for_gui(buf)

    %{
      mode: state.vim.mode,
      cursor_line: line + 1,
      cursor_col: col + 1,
      line_count: line_count,
      filetype: Filetype.detect(file_name),
      dirty_marker: if(buf && BufferServer.dirty?(buf), do: "●", else: ""),
      lsp_status: state.lsp_status,
      git_branch: resolve_git_branch(state),
      status_msg: state.status_msg,
      diagnostic_counts: diagnostic_counts
    }
  end

  @spec resolve_git_branch(state()) :: String.t() | nil
  defp resolve_git_branch(%{file_tree: %{tree: %{root: root}}}) do
    case Git.current_branch(root) do
      {:ok, branch} -> branch
      _ -> nil
    end
  end

  defp resolve_git_branch(_state), do: nil

  @spec diagnostic_counts_for_gui(pid() | nil) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  defp diagnostic_counts_for_gui(nil), do: nil

  defp diagnostic_counts_for_gui(buf) do
    path =
      try do
        BufferServer.file_path(buf)
      catch
        :exit, _ -> nil
      end

    case path do
      nil -> nil
      path -> Diagnostics.count_tuple(LspSyncServer.path_to_uri(path))
    end
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
      styled_cache = state.agent_ui.cached_styled_messages
      gui_messages = build_gui_messages(messages, styled_cache)

      prompt_text =
        case state.agent_ui.prompt_buffer do
          nil -> ""
          buf -> BufferServer.content(buf) |> String.trim_trailing("\n")
        end

      pending = state.agent.pending_approval

      %{
        visible: true,
        messages: gui_messages,
        status: state.agent.status || :idle,
        model: state.agent_ui.model_name,
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
end
