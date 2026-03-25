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
  alias Minga.Editor.MinibufferData
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.RenderPipeline.ContentHelpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.StatusBar.Data, as: StatusBarData
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window.Content

  alias Minga.Frontend.Protocol.GUI, as: ProtocolGUI
  alias Minga.UI.Picker

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  # ── Frame filtering ──────────────────────────────────────────────────────

  @doc """
  Filters a frame for GUI rendering.

  Most chrome fields are already empty from Chrome.GUI (tab bar, file tree,
  status bar, separators, minibuffer, overlays all use dedicated GUI opcodes).
  This filter handles the two remaining sources of draw_text content:

  1. **Splash screen** draws come from `Renderer`, not Chrome. Cleared here
     since the GUI could render a native splash.
  2. **Window content** (gutter, lines, tilde_lines) for buffer windows with
     semantic data (0x80 opcode). Gutter is cleared for all windows since the
     GUI renders it natively via 0x7B.
  """
  @spec filter_frame_for_gui(Frame.t()) :: Frame.t()
  def filter_frame_for_gui(frame) do
    %{
      frame
      | splash: nil,
        windows:
          Enum.map(frame.windows, fn wf ->
            # Buffer windows with semantic content get their text from the
            # 0x80 opcode, not draw_text. Strip lines + tilde_lines.
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
  Builds Metal-critical chrome commands that must be bundled with the
  main frame for atomic delivery.

  These commands write to LineBuffer state (gutter, cursorline, gutter
  separator) which the Metal render pass reads. If they arrive in a
  separate port message after `batch_end`, vsync can fire between them,
  causing blank or partially rendered frames.

  Returns encoded command binaries for the caller to bundle with the
  main frame commands before `batch_end`.
  """
  @spec build_metal_commands(state()) :: [binary()]
  def build_metal_commands(state) do
    build_gui_gutter_commands(state) ++
      build_gui_cursorline_commands(state) ++
      build_gui_gutter_separator_commands(state) ++
      build_gui_split_separator_commands(state)
  end

  @doc """
  Sends SwiftUI chrome data to the native frontend.

  These update `@Observable` properties on SwiftUI state objects
  (tab bar, file tree, status bar, picker, etc.). SwiftUI coalesces its
  own view updates independently of Metal vsync, so these are safe to
  send as separate port messages after the atomic Metal frame.

  Each chrome component uses fingerprint-based change detection via the
  process dictionary to skip re-encoding and re-sending when nothing
  changed. During j/k scroll, only the status bar (cursor position)
  changes; everything else is skipped. All changed chrome commands are
  batched into a single `Minga.Frontend.send_commands` call to reduce
  port write overhead.

  `status_bar_data` is pre-computed by the Chrome stage and passed through
  to avoid re-calling BufferServer for cursor/file info on the same frame.
  When nil (e.g. non-GUI fallback paths), it is computed here.
  """
  @spec sync_swiftui_chrome(state(), StatusBarData.t() | nil, MinibufferData.t() | nil) :: state()
  def sync_swiftui_chrome(state, status_bar_data \\ nil, minibuffer_data \\ nil) do
    sb_data = status_bar_data || StatusBarData.from_state(state)

    # Collect changed chrome commands into a single list.
    # Each build_gui_* function returns nil when the data hasn't changed
    # (fingerprint cache hit), or an encoded binary when it has.
    chrome_cmds =
      [
        build_gui_theme_cmd(state),
        build_gui_tab_bar_cmd(state),
        build_gui_agent_groups_cmd(state),
        build_gui_file_tree_cmd(state),
        build_gui_git_status_cmd(state),
        build_gui_which_key_cmd(state),
        build_gui_completion_cmd(state),
        build_gui_breadcrumb_cmd(state),
        build_gui_status_bar_cmd(state, sb_data),
        build_gui_picker_cmd(state),
        build_gui_agent_chat_cmd(state),
        build_gui_minibuffer_cmd(state, minibuffer_data),
        build_gui_hover_popup_cmd(state),
        build_gui_signature_help_cmd(state),
        build_gui_float_popup_cmd(state)
      ]
      |> Enum.reject(&is_nil/1)

    # Bottom panel is special: it returns updated message_store state.
    {panel_cmd, state} = build_gui_bottom_panel_cmd(state)
    chrome_cmds = if panel_cmd, do: chrome_cmds ++ [panel_cmd], else: chrome_cmds

    if chrome_cmds != [] do
      Minga.Frontend.send_commands(state.port_manager, chrome_cmds)
    end

    state
  end

  # ── Theme ──

  @spec build_gui_theme_cmd(state()) :: binary() | nil
  defp build_gui_theme_cmd(state) do
    theme_name = state.theme.name

    if theme_name != Process.get(:last_gui_theme) do
      Process.put(:last_gui_theme, theme_name)
      ProtocolGUI.encode_gui_theme(state.theme)
    end
  end

  # ── Tab bar ──

  @spec build_gui_tab_bar_cmd(state()) :: binary() | nil
  defp build_gui_tab_bar_cmd(%{tab_bar: %TabBar{} = tb} = state) do
    active_buf = active_window_buffer(state)
    fp = :erlang.phash2({tb, active_buf})

    if fp != Process.get(:last_gui_tab_bar_fp) do
      Process.put(:last_gui_tab_bar_fp, fp)
      ProtocolGUI.encode_gui_tab_bar(tb, active_buf)
    end
  end

  defp build_gui_tab_bar_cmd(%{tab_bar: nil}), do: nil

  @spec build_gui_agent_groups_cmd(state()) :: binary() | nil
  defp build_gui_agent_groups_cmd(%{tab_bar: %TabBar{} = tb}) do
    # Only send workspace bar when agent workspaces exist (tier >= 1).
    # Also include workspace count so the GUI hides the indicator when
    # all agent workspaces are removed.
    if TabBar.has_agent_groups?(tb) do
      fp = :erlang.phash2(tb.agent_groups)

      if fp != Process.get(:last_gui_agent_groups_fp) do
        Process.put(:last_gui_agent_groups_fp, fp)
        ProtocolGUI.encode_gui_agent_groups(tb)
      end
    else
      # No agent workspaces: send empty workspace bar to clear the GUI
      if Process.get(:last_gui_agent_groups_fp) != nil do
        Process.put(:last_gui_agent_groups_fp, nil)
        ProtocolGUI.encode_gui_agent_groups(tb)
      end
    end
  end

  defp build_gui_agent_groups_cmd(_), do: nil

  @spec active_window_buffer(state()) :: pid() | nil
  defp active_window_buffer(%{workspace: %{windows: %{active: win_id, map: map}}}) do
    case Map.get(map, win_id) do
      %{buffer: buf} when is_pid(buf) -> buf
      _ -> nil
    end
  end

  # ── File tree ──

  @spec build_gui_file_tree_cmd(state()) :: binary() | nil
  defp build_gui_file_tree_cmd(%{
         workspace: %{file_tree: %{tree: %Minga.Project.FileTree{} = tree}}
       }) do
    fp = :erlang.phash2(tree)

    if fp != Process.get(:last_gui_file_tree_fp) do
      Process.put(:last_gui_file_tree_fp, fp)
      ProtocolGUI.encode_gui_file_tree(tree)
    end
  end

  defp build_gui_file_tree_cmd(_state) do
    if Process.get(:last_gui_file_tree_fp) != :no_tree do
      Process.put(:last_gui_file_tree_fp, :no_tree)
      ProtocolGUI.encode_gui_file_tree(nil)
    end
  end

  # ── Git status panel ──

  @spec build_gui_git_status_cmd(state()) :: binary() | nil
  defp build_gui_git_status_cmd(%{git_status_panel: %{} = data}) do
    fp = :erlang.phash2(data)

    if fp != Process.get(:last_gui_git_status_fp) do
      Process.put(:last_gui_git_status_fp, fp)
      ProtocolGUI.encode_gui_git_status(data)
    end
  end

  defp build_gui_git_status_cmd(_state) do
    if Process.get(:last_gui_git_status_fp) != :no_git do
      Process.put(:last_gui_git_status_fp, :no_git)

      ProtocolGUI.encode_gui_git_status(%{
        repo_state: :not_a_repo,
        branch: "",
        ahead: 0,
        behind: 0,
        entries: []
      })
    end
  end

  # ── Which-key ──

  @spec build_gui_which_key_cmd(state()) :: binary() | nil
  defp build_gui_which_key_cmd(%{whichkey: wk}) do
    fp = :erlang.phash2(wk)

    if fp != Process.get(:last_gui_which_key_fp) do
      Process.put(:last_gui_which_key_fp, fp)
      ProtocolGUI.encode_gui_which_key(wk)
    end
  end

  # ── Completion ──

  @spec build_gui_completion_cmd(state()) :: binary() | nil
  defp build_gui_completion_cmd(%{workspace: %{completion: comp}} = state) do
    {cursor_row, cursor_col} = current_cursor_screen_pos(state)
    fp = :erlang.phash2({comp, cursor_row, cursor_col})

    if fp != Process.get(:last_gui_completion_fp) do
      Process.put(:last_gui_completion_fp, fp)
      ProtocolGUI.encode_gui_completion(comp, cursor_row, cursor_col)
    end
  end

  @spec current_cursor_screen_pos(state()) :: {non_neg_integer(), non_neg_integer()}
  defp current_cursor_screen_pos(state) do
    layout = Layout.get(state)

    case Layout.active_window_layout(layout, state) do
      %{content: {row, col, _w, _h}} ->
        buf = state.workspace.buffers.active

        if buf do
          {line, column} = BufferServer.cursor(buf)
          vp = state.workspace.viewport
          {row + line - vp.top, col + column}
        else
          {row, col}
        end

      nil ->
        {0, 0}
    end
  end

  # ── Breadcrumb ──

  @spec build_gui_breadcrumb_cmd(state()) :: binary() | nil
  defp build_gui_breadcrumb_cmd(state) do
    file_path = active_buffer_path(state)

    root =
      case state.workspace.file_tree do
        %{tree: %{root: r}} -> r
        _ -> ""
      end

    fp = :erlang.phash2({file_path, root})

    if fp != Process.get(:last_gui_breadcrumb_fp) do
      Process.put(:last_gui_breadcrumb_fp, fp)
      ProtocolGUI.encode_gui_breadcrumb(file_path, root)
    end
  end

  @spec active_buffer_path(state()) :: String.t() | nil
  defp active_buffer_path(state) do
    case state.workspace.buffers.active do
      nil -> nil
      buf -> BufferServer.file_path(buf)
    end
  end

  # ── Status bar ──
  # Status bar changes on every scroll frame (cursor line), so it's always sent.
  # No fingerprint caching; the encoding cost is small (fixed-size struct).

  @spec build_gui_status_bar_cmd(state(), StatusBarData.t()) :: binary()
  defp build_gui_status_bar_cmd(_state, status_bar_data) do
    ProtocolGUI.encode_gui_status_bar(status_bar_data)
  end

  # ── Minibuffer ──

  # Sends the gui_minibuffer opcode only when the data has changed since
  # the last frame. Uses a content hash to avoid re-encoding and resending
  # identical minibuffer state every render cycle.

  @spec build_gui_minibuffer_cmd(state(), MinibufferData.t() | nil) :: binary() | nil
  defp build_gui_minibuffer_cmd(_state, %MinibufferData{} = data) do
    fingerprint = minibuffer_fingerprint(data)

    if fingerprint != Process.get(:last_gui_minibuffer) do
      Process.put(:last_gui_minibuffer, fingerprint)
      ProtocolGUI.encode_gui_minibuffer(data)
    end
  end

  defp build_gui_minibuffer_cmd(_state, nil) do
    if Process.get(:last_gui_minibuffer) != :hidden do
      Process.put(:last_gui_minibuffer, :hidden)
      ProtocolGUI.encode_gui_minibuffer(%MinibufferData{visible: false})
    end
  end

  # Produces a lightweight fingerprint for change detection. Captures all
  # fields that affect the rendered output without allocating a full
  # encoded binary.
  @spec minibuffer_fingerprint(MinibufferData.t()) :: term()
  defp minibuffer_fingerprint(%MinibufferData{visible: false}), do: :hidden

  defp minibuffer_fingerprint(%MinibufferData{} = d) do
    {d.visible, d.mode, d.cursor_pos, d.prompt, d.input, d.context, d.selected_index,
     length(d.candidates),
     Enum.map(d.candidates, fn c -> {c.label, c.description, c.match_score} end)}
  end

  # ── Picker ──

  @spec build_gui_picker_cmd(state()) :: binary() | nil
  defp build_gui_picker_cmd(%{picker_ui: %{picker: nil}}) do
    if Process.get(:last_gui_picker_fp) != :closed do
      Process.put(:last_gui_picker_fp, :closed)
      picker_cmd = ProtocolGUI.encode_gui_picker(nil)
      preview_cmd = ProtocolGUI.encode_gui_picker_preview(nil)
      IO.iodata_to_binary([picker_cmd, preview_cmd])
    end
  end

  defp build_gui_picker_cmd(
         %{picker_ui: %{picker: picker, source: source, action_menu: action_menu}} = state
       ) do
    # Preview content is NOT in the fingerprint: a file changing on disk while
    # the picker is open won't refresh the preview. Acceptable trade-off for
    # scroll perf since the picker isn't open during normal editing.
    fp = :erlang.phash2({picker.query, picker.selected, Picker.total(picker), action_menu})

    if fp != Process.get(:last_gui_picker_fp) do
      Process.put(:last_gui_picker_fp, fp)
      has_preview = source != nil and Picker.Source.preview?(source)
      preview_lines = if has_preview, do: build_picker_preview(state)
      # Picker always pairs with its preview; concatenate so they arrive as
      # adjacent frames in the batched port write.
      picker_cmd = ProtocolGUI.encode_gui_picker(picker, has_preview, action_menu, 100)
      preview_cmd = ProtocolGUI.encode_gui_picker_preview(preview_lines)
      IO.iodata_to_binary([picker_cmd, preview_cmd])
    end
  end

  # Build preview content for the currently selected picker item.
  # Returns a list of lines, where each line is a list of {text, fg_color, bold} segments.
  @spec build_picker_preview(state()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp build_picker_preview(%{picker_ui: %{picker: picker}} = state) do
    case Picker.selected_item(picker) do
      nil ->
        nil

      %Picker.Item{id: id} ->
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
    case Enum.at(state.workspace.buffers.list, idx) do
      nil -> nil
      buf_pid -> preview_from_buffer(state, buf_pid)
    end
  end

  defp build_preview_for_item(_state, _id), do: nil

  @spec preview_from_buffer(state(), pid()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp preview_from_buffer(state, buf_pid) do
    case Map.get(state.workspace.highlight.highlights, buf_pid) do
      nil ->
        path = safe_file_path(buf_pid)
        if path, do: read_file_preview(path, state), else: nil

      highlight ->
        build_highlighted_preview(buf_pid, highlight, state)
    end
  end

  # Find a buffer PID for a given file path, along with its highlight state.
  @spec find_buffer_for_path(state(), String.t()) :: {pid(), Minga.UI.Highlight.t() | nil} | nil
  defp find_buffer_for_path(state, abs_path) do
    Enum.find_value(state.workspace.buffers.list, fn buf_pid ->
      try do
        case BufferServer.file_path(buf_pid) do
          ^abs_path ->
            highlight = Map.get(state.workspace.highlight.highlights, buf_pid)
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
  @spec build_highlighted_preview(pid(), Minga.UI.Highlight.t(), state()) ::
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

    styled_lines = Minga.UI.Highlight.styles_for_visible_lines(highlight, line_tuples)

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
  @spec face_to_rgb(Minga.UI.Face.t(), non_neg_integer()) :: non_neg_integer()
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

  @spec build_gui_agent_chat_cmd(state()) :: binary() | nil
  defp build_gui_agent_chat_cmd(state) do
    active_window = Map.get(state.workspace.windows.map, state.workspace.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)
    session = state.agent.session

    # Compute fingerprint from cheap state fields to avoid calling
    # AgentSession.messages (expensive GenServer.call that allocates a
    # formatted message list) on every frame. The prompt buffer content
    # is included because it's a single fast GenServer.call, and the PID
    # alone is stable (wouldn't detect typing). The styled cache length
    # is a reliable proxy for message count changes because styling
    # happens in the same render cycle as message arrival.
    # message_version is bumped on every :messages_changed event,
    # including collapse toggles, ensuring the fingerprint changes.
    {fp, prompt_text} =
      if is_agent_chat && session do
        panel = state.workspace.agent_ui.panel
        view = state.workspace.agent_ui.view
        styled_len = length(panel.cached_styled_messages || [])
        text = safe_prompt_content(panel.prompt_buffer)

        {:erlang.phash2(
           {:visible, state.agent.status, state.agent.pending_approval, styled_len,
            panel.model_name, text, panel.message_version, view.help_visible}
         ), text}
      else
        {:not_visible, ""}
      end

    if fp != Process.get(:last_gui_agent_chat_fp) do
      Process.put(:last_gui_agent_chat_fp, fp)
      data = build_agent_chat_data(state, prompt_text)

      if data.visible do
        Minga.Log.debug(:render, "[gui] sending agent chat: #{length(data.messages)} messages")
      end

      ProtocolGUI.encode_gui_agent_chat(data)
    end
  end

  # Reads prompt buffer content, guarding against a dead process.
  # The prompt buffer can die between state updates; the :DOWN handler
  # clears the PID on the next cycle, but there's a race window.
  @spec safe_prompt_content(pid() | nil) :: String.t()
  defp safe_prompt_content(nil), do: ""

  defp safe_prompt_content(buf) do
    BufferServer.content(buf) |> String.trim_trailing("\n")
  catch
    :exit, _ -> ""
  end

  @spec build_agent_chat_data(state(), String.t()) :: map()
  defp build_agent_chat_data(state, prompt_text) do
    active_window = Map.get(state.workspace.windows.map, state.workspace.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)
    session = state.agent.session

    if is_agent_chat && session do
      messages_with_ids =
        try do
          AgentSession.messages_with_ids(session)
        catch
          :exit, _ -> []
        end

      # Use cached styled runs for assistant messages when available.
      # This avoids recomputing tree-sitter/markdown styling per frame.
      styled_cache = state.workspace.agent_ui.panel.cached_styled_messages
      gui_messages = build_gui_messages(messages_with_ids, styled_cache)

      view = state.workspace.agent_ui.view
      help_visible = view.help_visible

      help_groups =
        if help_visible do
          Minga.Keymap.Scope.Agent.help_groups(view.focus)
        else
          []
        end

      %{
        visible: true,
        messages: gui_messages,
        status: state.agent.status || :idle,
        model: state.workspace.agent_ui.panel.model_name,
        prompt: prompt_text,
        pending_approval: state.agent.pending_approval,
        help_visible: help_visible,
        help_groups: help_groups
      }
    else
      %{visible: false}
    end
  end

  # Builds the message list for GUI encoding. Each entry is `{id, gui_message}`
  # where `id` is the stable BEAM-assigned message ID. Replaces assistant messages
  # with {:styled_assistant, styled_lines} when cached styled runs are available.
  #
  # Input: list of `{id, Message.t()}` pairs from `messages_with_ids/1`.
  # Uses Enum.zip (O(n)) instead of Enum.at in a loop (O(n²)) since this
  # runs every render frame at 60fps.
  @spec build_gui_messages([{pos_integer(), term()}], [term()] | nil) :: [{pos_integer(), term()}]
  defp build_gui_messages(messages_with_ids, nil), do: messages_with_ids

  defp build_gui_messages(messages_with_ids, styled_cache) when is_list(styled_cache) do
    # Pad the cache to match message length if needed (messages may have grown)
    padded = pad_cache(styled_cache, length(messages_with_ids))

    Enum.zip(messages_with_ids, padded)
    |> Enum.map(&maybe_style_message/1)
  end

  @spec maybe_style_message({{pos_integer(), term()}, term()}) :: {pos_integer(), term()}
  defp maybe_style_message({{id, {:assistant, _text} = msg}, nil}), do: {id, msg}

  defp maybe_style_message({{id, {:assistant, _text}}, styled_lines}),
    do: {id, {:styled_assistant, styled_lines}}

  defp maybe_style_message({{id, {:tool_call, tc}}, styled_lines}) when is_list(styled_lines),
    do: {id, {:styled_tool_call, tc, styled_lines}}

  defp maybe_style_message({{id, msg}, _cache_entry}), do: {id, msg}

  @spec pad_cache([term()], non_neg_integer()) :: [term()]
  defp pad_cache(cache, target_len) when length(cache) >= target_len, do: cache
  defp pad_cache(cache, target_len), do: cache ++ List.duplicate(nil, target_len - length(cache))

  # ── Gutter separator ──

  @spec build_gui_gutter_separator_commands(state()) :: [binary()]
  defp build_gui_gutter_separator_commands(state) do
    show? = Options.get(:show_gutter_separator)
    active_window = Map.get(state.workspace.windows.map, state.workspace.windows.active)
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

    [ProtocolGUI.encode_gui_gutter_separator(max(col, 0), color_rgb)]
  end

  # ── Cursorline ──

  @spec build_gui_cursorline_commands(state()) :: [binary()]
  defp build_gui_cursorline_commands(state) do
    active_window = Map.get(state.workspace.windows.map, state.workspace.windows.active)
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

    [ProtocolGUI.encode_gui_cursorline(row, bg_rgb)]
  end

  # ── Gutter ──

  @spec build_gui_gutter_commands(state()) :: [binary()]
  defp build_gui_gutter_commands(state) do
    layout = Layout.get(state)

    Enum.flat_map(layout.window_layouts, fn {win_id, win_layout} ->
      window = Map.get(state.workspace.windows.map, win_id)

      # Skip agent chat windows (they don't have gutter)
      if window && is_pid(window.buffer) && !Content.agent_chat?(window.content) do
        is_active = win_id == state.workspace.windows.active
        gutter_data = build_window_gutter(state, window, win_id, win_layout, is_active)
        [ProtocolGUI.encode_gui_gutter(gutter_data)]
      else
        []
      end
    end)
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

    # Sign column is always reserved for consistent gutter layout.
    sign_col_width = Minga.Editor.Renderer.Gutter.sign_column_width()

    line_number_width =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    # Get signs and decorations for the buffer
    decorations = BufferServer.decorations(buf)
    diag_signs = ContentHelpers.diagnostic_signs_for_window(state, window)
    git_signs = ContentHelpers.git_signs_for_window(state, window)

    # Build entries for each visible line
    entries =
      for row <- 0..(win_pos.content_height - 1) do
        buf_line = viewport_top + row

        if buf_line < line_count do
          resolve_gutter_entry(buf_line, diag_signs, git_signs, decorations)
        else
          %{buf_line: buf_line, display_type: :normal, sign_type: :none}
        end
      end

    Map.merge(win_pos, %{
      cursor_line: cursor_line,
      line_number_style: line_number_style,
      line_number_width: line_number_width,
      sign_col_width: sign_col_width,
      entries: entries
    })
  end

  # Resolves the gutter entry for a buffer line. Diagnostics > git signs > annotations.
  @spec resolve_gutter_entry(
          non_neg_integer(),
          %{non_neg_integer() => atom()},
          %{non_neg_integer() => atom()},
          Minga.Buffer.Decorations.t()
        ) :: ProtocolGUI.gutter_entry()
  defp resolve_gutter_entry(buf_line, diag_signs, git_signs, decorations) do
    sign_type = resolve_sign_type(buf_line, diag_signs, git_signs)

    case sign_type do
      :none ->
        resolve_annotation_entry(buf_line, decorations)

      _ ->
        %{buf_line: buf_line, display_type: :normal, sign_type: sign_type}
    end
  end

  # Checks for :gutter_icon annotations when no diagnostic or git sign is present.
  @spec resolve_annotation_entry(non_neg_integer(), Minga.Buffer.Decorations.t()) ::
          ProtocolGUI.gutter_entry()
  defp resolve_annotation_entry(buf_line, decorations) do
    icons =
      decorations
      |> Minga.Buffer.Decorations.annotations_for_line(buf_line)
      |> Enum.filter(fn ann -> ann.kind == :gutter_icon end)

    case icons do
      [] ->
        %{buf_line: buf_line, display_type: :normal, sign_type: :none}

      [ann | _] ->
        %{
          buf_line: buf_line,
          display_type: :normal,
          sign_type: :annotation,
          sign_fg: ann.fg,
          sign_text: String.slice(ann.text, 0, 2)
        }
    end
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

  # ── Hover popup ──

  @spec build_gui_hover_popup_cmd(state()) :: binary() | nil
  defp build_gui_hover_popup_cmd(%{shell_state: %{hover_popup: popup}}) do
    fp = :erlang.phash2(popup)

    if fp != Process.get(:last_gui_hover_popup_fp) do
      Process.put(:last_gui_hover_popup_fp, fp)
      ProtocolGUI.encode_gui_hover_popup(popup)
    end
  end

  # ── Signature help ──

  @spec build_gui_signature_help_cmd(state()) :: binary() | nil
  defp build_gui_signature_help_cmd(%{signature_help: sh}) do
    fp = :erlang.phash2(sh)

    if fp != Process.get(:last_gui_signature_help_fp) do
      Process.put(:last_gui_signature_help_fp, fp)
      ProtocolGUI.encode_gui_signature_help(sh)
    end
  end

  # ── Split separators ──

  @spec build_gui_split_separator_commands(state()) :: [binary()]
  defp build_gui_split_separator_commands(state) do
    if EditorState.split?(state) do
      layout = Layout.get(state)
      border_color = state.theme.editor.split_border_fg

      # Collect vertical separators from the window tree
      verticals =
        ChromeHelpers.collect_vertical_separators(
          state.workspace.windows.tree,
          layout.editor_area
        )

      # Horizontal separators from layout
      horizontals = layout.horizontal_separators

      [ProtocolGUI.encode_gui_split_separators(border_color, verticals, horizontals)]
    else
      # No splits: send empty separator data to clear any previous state
      [ProtocolGUI.encode_gui_split_separators(0, [], [])]
    end
  end

  # ── Float popup ──

  @spec build_gui_float_popup_cmd(state()) :: binary() | nil
  defp build_gui_float_popup_cmd(state) do
    float_window = find_float_popup_window(state)

    fp = :erlang.phash2(float_window && {float_window.buffer, float_window.popup_meta})

    if fp != Process.get(:last_gui_float_popup_fp) do
      Process.put(:last_gui_float_popup_fp, fp)

      if float_window do
        data = build_float_popup_data(state, float_window)
        ProtocolGUI.encode_gui_float_popup(data)
      else
        ProtocolGUI.encode_gui_float_popup(%{
          visible: false,
          title: "",
          lines: [],
          width: 0,
          height: 0
        })
      end
    end
  end

  @spec find_float_popup_window(state()) :: Minga.Editor.Window.t() | nil
  defp find_float_popup_window(state) do
    Enum.find_value(state.workspace.windows.map, fn
      {_id,
       %{popup_meta: %Minga.UI.Popup.Active{rule: %Minga.UI.Popup.Rule{display: :float}}} = w} ->
        w

      _ ->
        nil
    end)
  end

  @spec build_float_popup_data(state(), Minga.Editor.Window.t()) :: ProtocolGUI.float_popup_data()
  defp build_float_popup_data(state, window) do
    rule = window.popup_meta.rule
    vp = state.workspace.viewport

    width = resolve_float_dim(rule, :width, vp.cols)
    height = resolve_float_dim(rule, :height, vp.rows)

    # Interior dimensions (subtract 2 for border)
    interior_h = max(height - 2, 1)
    interior_w = max(width - 2, 1)

    {title, lines} =
      try do
        name = BufferServer.buffer_name(window.buffer)
        snapshot = BufferServer.render_snapshot(window.buffer, 0, interior_h)
        trimmed = Enum.map(snapshot.lines, &String.slice(&1, 0, interior_w))
        {name, trimmed}
      catch
        :exit, _ -> {"", []}
      end

    %{visible: true, title: title, lines: lines, width: width, height: height}
  end

  @spec resolve_float_dim(Minga.UI.Popup.Rule.t(), :width | :height, pos_integer()) ::
          pos_integer()
  defp resolve_float_dim(rule, dim, viewport_size) do
    val =
      case dim do
        :width -> rule.width || rule.size || {:percent, 50}
        :height -> rule.height || rule.size || {:percent, 50}
      end

    case val do
      {:percent, pct} -> max(div(viewport_size * pct, 100), 1)
      {:cols, n} -> n
      {:rows, n} -> n
      n when is_integer(n) -> n
      _ -> max(div(viewport_size, 2), 1)
    end
  end

  # ── Bottom panel ──

  # Bottom panel is special: it returns {cmd | nil, updated_state} because
  # encode_gui_bottom_panel may advance the message_store cursor when new
  # entries have arrived. We still fingerprint to skip encoding when the
  # panel hasn't changed.
  @spec build_gui_bottom_panel_cmd(state()) :: {binary() | nil, state()}
  defp build_gui_bottom_panel_cmd(%{bottom_panel: panel, message_store: store} = state) do
    fp = :erlang.phash2({panel, store})

    if fp != Process.get(:last_gui_bottom_panel_fp) do
      Process.put(:last_gui_bottom_panel_fp, fp)
      {cmd, new_store} = ProtocolGUI.encode_gui_bottom_panel(panel, store)
      {cmd, %{state | message_store: new_store}}
    else
      {nil, state}
    end
  end
end
