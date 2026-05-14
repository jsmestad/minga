defmodule MingaEditor.Frontend.Emit.GUI do
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

  alias MingaAgent.Session, as: AgentSession
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.PromptSemanticWindow
  alias Minga.Buffer
  alias Minga.Config

  alias MingaEditor.DisplayList.Frame
  alias MingaEditor.Layout
  alias MingaEditor.MinibufferData
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Shell.Traditional.Chrome.Helpers, as: ChromeHelpers
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.State.TabBar
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.Viewport
  alias MingaEditor.Window.Content
  alias MingaEditor.Frontend.Emit.Context

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.UI.Picker

  @typedoc "Emit context for the GUI stage."
  @type ctx :: Context.t()

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
  @spec build_metal_commands(ctx()) :: [binary()]
  def build_metal_commands(ctx) do
    build_gui_gutter_commands(ctx) ++
      build_gui_cursorline_commands(ctx) ++
      build_gui_gutter_separator_commands(ctx) ++
      build_gui_split_separator_commands(ctx) ++
      build_gui_indent_guide_commands(ctx)
  end

  @doc """
  Sends SwiftUI chrome data to the native frontend.

  These update `@Observable` properties on SwiftUI state objects
  (tab bar, file tree, status bar, picker, etc.). SwiftUI coalesces its
  own view updates independently of Metal vsync, so these are safe to
  send as separate port messages after the atomic Metal frame.

  Each chrome component uses fingerprint-based change detection via the
  `Caches` struct to skip re-encoding and re-sending when nothing changed.
  During j/k scroll, only the status bar (cursor position) changes;
  everything else is skipped. All changed chrome commands are batched into
  a single `MingaEditor.Frontend.send_commands` call to reduce port write
  overhead.

  `status_bar_data` is pre-computed by the Chrome stage and passed through
  to avoid re-calling Buffer for cursor/file info on the same frame.
  When nil (e.g. non-GUI fallback paths), it is computed here.
  """
  @spec sync_swiftui_chrome(ctx(), StatusBarData.t() | nil, MinibufferData.t() | nil, Caches.t()) ::
          {ctx(), Caches.t()}
  def sync_swiftui_chrome(ctx, status_bar_data, minibuffer_data, caches) do
    sb_data = status_bar_data || ctx.status_bar_data

    # Use map_reduce to thread caches through each builder function.
    # Each build_gui_* function returns {cmd | nil, updated_caches}.
    builders = [
      &build_gui_theme_cmd/2,
      &build_gui_tab_bar_cmd/2,
      &build_gui_agent_groups_cmd/2,
      &build_gui_file_tree_cmd/2,
      &build_gui_git_status_cmd/2,
      &build_gui_which_key_cmd/2,
      &build_gui_completion_cmd/2,
      &build_gui_breadcrumb_cmd/2,
      fn ctx, caches -> build_gui_status_bar_cmd(ctx, sb_data, caches) end,
      &build_gui_picker_cmd/2,
      &build_gui_agent_chat_cmd/2,
      fn ctx, caches -> build_gui_minibuffer_cmd(ctx, minibuffer_data, caches) end,
      &build_gui_hover_popup_cmd/2,
      &build_gui_signature_help_cmd/2,
      &build_gui_float_popup_cmd/2,
      &build_gui_board_cmd/2,
      &build_gui_agent_context_cmd/2,
      &build_gui_change_summary_cmd/2
    ]

    {cmds, caches} =
      Enum.map_reduce(builders, caches, fn build_fn, acc_caches ->
        build_fn.(ctx, acc_caches)
      end)

    chrome_cmds = Enum.reject(cmds, &is_nil/1)

    # Bottom panel is special: it also returns updated ctx (for message_store).
    {panel_cmd, ctx, caches} = build_gui_bottom_panel_cmd(ctx, caches)
    chrome_cmds = if panel_cmd, do: chrome_cmds ++ [panel_cmd], else: chrome_cmds

    if chrome_cmds != [] do
      MingaEditor.Frontend.send_commands(ctx.port_manager, chrome_cmds)
    end

    {ctx, caches}
  end

  # ── Theme ──

  @spec build_gui_theme_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_theme_cmd(ctx, caches) do
    theme_fp = theme_fingerprint(ctx.theme)

    if theme_fp != caches.last_gui_theme do
      {ProtocolGUI.encode_gui_theme(ctx.theme), %{caches | last_gui_theme: theme_fp}}
    else
      {nil, caches}
    end
  end

  @spec theme_fingerprint(MingaEditor.UI.Theme.t()) :: integer()
  defp theme_fingerprint(theme) do
    :erlang.phash2({
      theme.name,
      MingaEditor.UI.Theme.Slots.to_color_pairs(theme)
    })
  end

  # ── Tab bar ──

  @spec build_gui_tab_bar_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}

  # Board: no tab bar (Board manages its own navigation)
  defp build_gui_tab_bar_cmd(%{shell: MingaEditor.Shell.Board}, caches), do: {nil, caches}

  defp build_gui_tab_bar_cmd(%{shell_state: %{tab_bar: %TabBar{} = tb}} = ctx, caches) do
    active_buf = active_window_buffer(ctx)
    fp = :erlang.phash2({tb, active_buf})

    if fp != caches.last_gui_tab_bar_fp do
      {ProtocolGUI.encode_gui_tab_bar(tb, active_buf), %{caches | last_gui_tab_bar_fp: fp}}
    else
      {nil, caches}
    end
  end

  defp build_gui_tab_bar_cmd(%{shell_state: %{tab_bar: nil}}, caches), do: {nil, caches}

  @spec build_gui_agent_groups_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_agent_groups_cmd(%{shell_state: %{tab_bar: %TabBar{} = tb}}, caches) do
    # Only send workspace bar when agent workspaces exist (tier >= 1).
    # Also include workspace count so the GUI hides the indicator when
    # all agent workspaces are removed.
    if TabBar.has_agent_groups?(tb) do
      fp = agent_groups_fingerprint(tb)

      if fp != caches.last_gui_agent_groups_fp do
        {ProtocolGUI.encode_gui_agent_groups(tb), %{caches | last_gui_agent_groups_fp: fp}}
      else
        {nil, caches}
      end
    else
      # No agent workspaces: send empty workspace bar to clear the GUI
      if caches.last_gui_agent_groups_fp != nil do
        {ProtocolGUI.encode_gui_agent_groups(tb), %{caches | last_gui_agent_groups_fp: nil}}
      else
        {nil, caches}
      end
    end
  end

  defp build_gui_agent_groups_cmd(_ctx, caches), do: {nil, caches}

  @spec agent_groups_fingerprint(TabBar.t()) :: integer()
  defp agent_groups_fingerprint(%TabBar{} = tb) do
    :erlang.phash2({
      TabBar.active_group_id(tb),
      Enum.map(tb.agent_groups, fn group ->
        {group.id, group.label, group.icon, group.color, group.agent_status,
         length(TabBar.tabs_in_group(tb, group.id))}
      end)
    })
  end

  @spec active_window_buffer(ctx()) :: pid() | nil
  defp active_window_buffer(%{windows: %{active: win_id, map: map}}) do
    case Map.get(map, win_id) do
      %{buffer: buf} when is_pid(buf) -> buf
      _ -> nil
    end
  end

  # ── File tree ──

  @spec build_gui_file_tree_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_file_tree_cmd(
         %{file_tree: %{tree: %Minga.Project.FileTree{} = tree, editing: editing}},
         caches
       ) do
    fp = :erlang.phash2({tree, editing})

    if fp != caches.last_gui_file_tree_fp do
      {ProtocolGUI.encode_gui_file_tree(tree, editing), %{caches | last_gui_file_tree_fp: fp}}
    else
      {nil, caches}
    end
  end

  defp build_gui_file_tree_cmd(%{file_tree: %{project_root: root_path}}, caches) do
    build_hidden_gui_file_tree_cmd(root_path, caches)
  end

  defp build_gui_file_tree_cmd(_ctx, caches) do
    build_hidden_gui_file_tree_cmd(nil, caches)
  end

  @spec build_hidden_gui_file_tree_cmd(String.t() | nil, Caches.t()) ::
          {binary() | nil, Caches.t()}
  defp build_hidden_gui_file_tree_cmd(root_path, caches) do
    fp = {:no_tree, root_path || ""}

    if caches.last_gui_file_tree_fp != fp do
      {ProtocolGUI.encode_hidden_gui_file_tree(root_path), %{caches | last_gui_file_tree_fp: fp}}
    else
      {nil, caches}
    end
  end

  # ── Git status panel ──

  @spec build_gui_git_status_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_git_status_cmd(
         %{shell_state: %{git_status_panel: %{} = data}, git_syncing: syncing, git_toast: toast},
         caches
       ) do
    enriched = Map.merge(data, %{syncing: syncing, git_toast: toast})
    fp = :erlang.phash2(enriched)

    if fp != caches.last_gui_git_status_fp do
      {ProtocolGUI.encode_gui_git_status(enriched), %{caches | last_gui_git_status_fp: fp}}
    else
      {nil, caches}
    end
  end

  defp build_gui_git_status_cmd(%{git_syncing: syncing, git_toast: toast}, caches) do
    fp = {:no_git, syncing, toast}

    if caches.last_gui_git_status_fp != fp do
      cmd =
        ProtocolGUI.encode_gui_git_status(%{
          repo_state: :not_a_repo,
          syncing: syncing,
          branch: "",
          ahead: 0,
          behind: 0,
          entries: [],
          git_toast: toast
        })

      {cmd, %{caches | last_gui_git_status_fp: fp}}
    else
      {nil, caches}
    end
  end

  # ── Which-key ──

  @spec build_gui_which_key_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_which_key_cmd(%{shell_state: %{whichkey: wk}}, caches) do
    fp = :erlang.phash2(wk)

    if fp != caches.last_gui_which_key_fp do
      {ProtocolGUI.encode_gui_which_key(wk), %{caches | last_gui_which_key_fp: fp}}
    else
      {nil, caches}
    end
  end

  # ── Completion ──

  @spec build_gui_completion_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_completion_cmd(%{completion: comp} = ctx, caches) do
    {cursor_row, cursor_col} = current_cursor_screen_pos(ctx)
    fp = :erlang.phash2({comp, cursor_row, cursor_col})

    if fp != caches.last_gui_completion_fp do
      {ProtocolGUI.encode_gui_completion(comp, cursor_row, cursor_col),
       %{caches | last_gui_completion_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec current_cursor_screen_pos(ctx()) :: {non_neg_integer(), non_neg_integer()}
  defp current_cursor_screen_pos(ctx) do
    layout = ctx.layout

    case Map.get(layout.window_layouts, ctx.windows.active) do
      %{content: {row, col, _w, _h}} ->
        buf = ctx.buffers.active

        if buf do
          {line, column} = Buffer.cursor(buf)
          vp = ctx.viewport
          {row + line - vp.top, col + column}
        else
          {row, col}
        end

      nil ->
        {0, 0}
    end
  end

  # ── Breadcrumb ──

  @spec build_gui_breadcrumb_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_breadcrumb_cmd(ctx, caches) do
    file_path = active_buffer_path(ctx)

    root =
      case ctx.file_tree do
        %{tree: %{root: r}} -> r
        _ -> ""
      end

    fp = :erlang.phash2({file_path, root})

    if fp != caches.last_gui_breadcrumb_fp do
      {ProtocolGUI.encode_gui_breadcrumb(file_path, root), %{caches | last_gui_breadcrumb_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec active_buffer_path(ctx()) :: String.t() | nil
  defp active_buffer_path(ctx) do
    case ctx.buffers.active do
      nil -> nil
      buf -> Buffer.file_path(buf)
    end
  end

  # ── Status bar ──
  # Status bar changes on every scroll frame (cursor line), so it's always sent.
  # No fingerprint caching; the encoding cost is small (fixed-size struct).

  @spec build_gui_status_bar_cmd(ctx(), StatusBarData.t(), Caches.t()) :: {binary(), Caches.t()}
  defp build_gui_status_bar_cmd(_ctx, status_bar_data, caches) do
    {ProtocolGUI.encode_gui_status_bar(status_bar_data), caches}
  end

  # ── Minibuffer ──

  # Sends the gui_minibuffer opcode only when the data has changed since
  # the last frame. Uses a content hash to avoid re-encoding and resending
  # identical minibuffer state every render cycle.

  @spec build_gui_minibuffer_cmd(ctx(), MinibufferData.t() | nil, Caches.t()) ::
          {binary() | nil, Caches.t()}
  defp build_gui_minibuffer_cmd(_ctx, %MinibufferData{} = data, caches) do
    fingerprint = minibuffer_fingerprint(data)

    if fingerprint != caches.last_gui_minibuffer do
      {ProtocolGUI.encode_gui_minibuffer(data), %{caches | last_gui_minibuffer: fingerprint}}
    else
      {nil, caches}
    end
  end

  defp build_gui_minibuffer_cmd(_ctx, nil, caches) do
    if caches.last_gui_minibuffer != :hidden do
      {ProtocolGUI.encode_gui_minibuffer(%MinibufferData{visible: false}),
       %{caches | last_gui_minibuffer: :hidden}}
    else
      {nil, caches}
    end
  end

  # Produces a lightweight fingerprint for change detection. Captures all
  # fields that affect the rendered output without allocating a full
  # encoded binary.
  @spec minibuffer_fingerprint(MinibufferData.t()) :: term()
  defp minibuffer_fingerprint(%MinibufferData{visible: false}), do: :hidden

  defp minibuffer_fingerprint(%MinibufferData{} = d) do
    {d.visible, d.mode, d.cursor_pos, d.prompt, d.input, d.context, d.selected_index,
     length(d.candidates), d.total_candidates,
     Enum.map(d.candidates, fn c ->
       {c.label, c.description, c.match_score, Map.get(c, :annotation, ""),
        Map.get(c, :match_positions, [])}
     end)}
  end

  # ── Picker ──

  @spec build_gui_picker_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_picker_cmd(ctx, caches) do
    case ctx.shell_state.modal do
      {:picker, %{picker_ui: %{picker: picker, source: source, action_menu: action_menu}}}
      when picker != nil ->
        do_build_gui_picker_cmd(ctx, picker, source, action_menu, caches)

      _ ->
        if caches.last_gui_picker_fp != :closed do
          picker_cmd = ProtocolGUI.encode_gui_picker(nil)
          preview_cmd = ProtocolGUI.encode_gui_picker_preview(nil)

          {IO.iodata_to_binary([picker_cmd, preview_cmd]),
           %{caches | last_gui_picker_fp: :closed}}
        else
          {nil, caches}
        end
    end
  end

  @spec do_build_gui_picker_cmd(ctx(), term(), module() | nil, term(), Caches.t()) ::
          {binary() | nil, Caches.t()}
  defp do_build_gui_picker_cmd(ctx, picker, source, action_menu, caches) do
    # Preview content is NOT in the fingerprint: a file changing on disk while
    # the picker is open won't refresh the preview. Acceptable trade-off for
    # scroll perf since the picker isn't open during normal editing.
    has_preview = source != nil and Picker.Source.preview?(source)
    fp = picker_fingerprint(picker, has_preview, action_menu, 100)

    if fp != caches.last_gui_picker_fp do
      preview_lines = if has_preview, do: build_picker_preview(ctx)
      # Picker always pairs with its preview; concatenate so they arrive as
      # adjacent frames in the batched port write.
      picker_cmd = ProtocolGUI.encode_gui_picker(picker, has_preview, action_menu, 100)
      preview_cmd = ProtocolGUI.encode_gui_picker_preview(preview_lines)
      {IO.iodata_to_binary([picker_cmd, preview_cmd]), %{caches | last_gui_picker_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec picker_fingerprint(Picker.t(), boolean(), term(), non_neg_integer()) :: integer()
  defp picker_fingerprint(picker, has_preview, action_menu, max_items) do
    limit = if max_items > 0, do: max_items, else: picker.max_visible

    visible_items =
      picker.filtered
      |> Enum.take(limit)
      |> Enum.map(fn item ->
        {item.id, item.label, item.description, item.annotation, item.icon_color, item.two_line,
         item.match_positions, Picker.marked?(picker, item)}
      end)

    :erlang.phash2({
      picker.title,
      picker.query,
      picker.selected,
      length(picker.filtered),
      length(picker.items),
      has_preview,
      visible_items,
      action_menu
    })
  end

  # Build preview content for the currently selected picker item.
  # Returns a list of lines, where each line is a list of {text, fg_color, bold} segments.
  @spec build_picker_preview(ctx()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp build_picker_preview(
         %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker}}}}} = ctx
       ) do
    case Picker.selected_item(picker) do
      nil ->
        nil

      %Picker.Item{id: id} ->
        build_preview_for_item(ctx, id)
    end
  end

  # Build preview lines for a file path item.
  # Uses syntax highlighting from an open buffer when available, falls back to plain text.
  @spec build_preview_for_item(ctx(), term()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp build_preview_for_item(ctx, id) when is_binary(id) do
    abs_path = resolve_preview_path(id)

    # Check if the file is already open in a buffer with highlights
    case find_buffer_for_path(ctx, abs_path) do
      {buf_pid, highlight} when highlight != nil ->
        build_highlighted_preview(buf_pid, highlight, ctx)

      _ ->
        read_file_preview(abs_path, ctx)
    end
  end

  # For buffer index items, use the buffer directly.
  defp build_preview_for_item(ctx, idx) when is_integer(idx) do
    case Enum.at(ctx.buffers.list, idx) do
      nil -> nil
      buf_pid -> preview_from_buffer(ctx, buf_pid)
    end
  end

  defp build_preview_for_item(_ctx, _id), do: nil

  @spec preview_from_buffer(ctx(), pid()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp preview_from_buffer(ctx, buf_pid) do
    case Map.get(ctx.highlight.highlights, buf_pid) do
      nil ->
        path = safe_file_path(buf_pid)
        if path, do: read_file_preview(path, ctx), else: nil

      highlight ->
        build_highlighted_preview(buf_pid, highlight, ctx)
    end
  end

  # Find a buffer PID for a given file path, along with its highlight state.
  @spec find_buffer_for_path(ctx(), String.t()) ::
          {pid(), MingaEditor.UI.Highlight.t() | nil} | nil
  defp find_buffer_for_path(ctx, abs_path) do
    Enum.find_value(ctx.buffers.list, fn buf_pid ->
      try do
        case Buffer.file_path(buf_pid) do
          ^abs_path ->
            highlight = Map.get(ctx.highlight.highlights, buf_pid)
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
  @spec build_highlighted_preview(pid(), MingaEditor.UI.Highlight.t(), ctx()) ::
          [[ProtocolGUI.preview_segment()]] | nil
  defp build_highlighted_preview(buf_pid, highlight, ctx) do
    content = Buffer.content(buf_pid)
    lines = content |> String.split("\n") |> Enum.take(@preview_max_lines)
    default_fg = Map.get(ctx.theme, :fg, 0xCCCCCC)

    # Build {line_text, byte_offset} tuples for batch highlighting
    {line_tuples, _} =
      Enum.map_reduce(lines, 0, fn line, offset ->
        # +1 for the newline byte
        {{line, offset}, offset + byte_size(line) + 1}
      end)

    styled_lines = MingaEditor.UI.Highlight.styles_for_visible_lines(highlight, line_tuples)

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
  @spec face_to_rgb(Minga.Core.Face.t(), non_neg_integer()) :: non_neg_integer()
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
  @spec read_file_preview(String.t(), ctx()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp read_file_preview(abs_path, ctx) do
    case File.read(abs_path) do
      {:ok, content} ->
        fg_color = Map.get(ctx.theme, :fg, 0xCCCCCC)

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
    Buffer.file_path(pid)
  catch
    :exit, _ -> nil
  end

  # ── Agent chat ──

  @spec build_gui_agent_chat_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_agent_chat_cmd(ctx, caches) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)
    session = ctx.shell.active_session(ctx.shell_state)

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
        panel = ctx.agent_ui.panel
        view = ctx.agent_ui.view
        styled_len = length(panel.cached_styled_messages || [])
        text = safe_prompt_content(panel.prompt_buffer)
        prompt_cursor = UIState.input_cursor(panel)
        prompt_line_count = UIState.input_line_count(panel)
        inner_width = max(ctx.viewport.cols - 10, 20)
        visible_rows = PromptSemanticWindow.visible_rows(panel, inner_width)

        {:erlang.phash2(
           {:visible, ctx.shell_state.agent.runtime.status,
            ctx.shell_state.agent.pending_approval, styled_len, panel.model_name, text,
            panel.message_version, view.help_visible, view.focus, ctx.editing.mode, prompt_cursor,
            prompt_line_count, visible_rows, panel.mention_completion}
         ), text}
      else
        {:not_visible, ""}
      end

    if fp != caches.last_gui_agent_chat_fp do
      data = build_agent_chat_data(ctx, prompt_text)

      if data.visible do
        log_agent_chat_message_stats(data.messages)
      end

      {ProtocolGUI.encode_gui_agent_chat(data), %{caches | last_gui_agent_chat_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec log_agent_chat_message_stats([{pos_integer(), term()}]) :: :ok
  defp log_agent_chat_message_stats(messages) do
    {styled, plain} =
      Enum.reduce(messages, {0, 0}, fn
        {_, {:styled_assistant, _}}, {s, p} -> {s + 1, p}
        {_, {:styled_tool_call, _, _}}, {s, p} -> {s + 1, p}
        {_, {:assistant, _}}, {s, p} -> {s, p + 1}
        _, acc -> acc
      end)

    Minga.Log.debug(
      :render,
      "[gui] sending agent chat: #{length(messages)} msgs (#{styled} styled, #{plain} plain assistant)"
    )
  end

  # Builds the prompt completion popup data for @-mention or /slash completion.
  # Returns a map suitable for encode_prompt_completion, or nil if no completion active.
  @spec build_prompt_completion(MingaEditor.Agent.UIState.Panel.t()) :: map() | nil
  defp build_prompt_completion(%{mention_completion: %{candidates: candidates} = comp})
       when is_list(candidates) and candidates != [] do
    # Slash completions carry {name, description} tuples in :slash_candidates.
    # Mention completions are plain file path strings.
    {type, formatted_candidates} =
      case comp[:slash_candidates] do
        slash when is_list(slash) and slash != [] ->
          {:slash, slash}

        _ ->
          {:mention, candidates}
      end

    %{
      type: type,
      candidates: formatted_candidates,
      selected: comp.selected,
      anchor_line: comp.anchor_line,
      anchor_col: comp.anchor_col
    }
  end

  defp build_prompt_completion(_panel), do: nil

  # Reads prompt buffer content, guarding against a dead process.
  # The prompt buffer can die between state updates; the :DOWN handler
  # clears the PID on the next cycle, but there's a race window.
  @spec safe_prompt_content(pid() | nil) :: String.t()
  defp safe_prompt_content(nil), do: ""

  defp safe_prompt_content(buf) do
    Buffer.content(buf) |> String.trim_trailing("\n")
  catch
    :exit, _ -> ""
  end

  @spec build_agent_chat_data(ctx(), String.t()) :: map()
  defp build_agent_chat_data(ctx, prompt_text) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)
    session = ctx.shell.active_session(ctx.shell_state)

    if is_agent_chat && session do
      messages_with_ids =
        try do
          AgentSession.messages_with_ids(session)
        catch
          :exit, _ -> []
        end

      # Use cached styled runs for assistant messages when available.
      # This avoids recomputing tree-sitter/markdown styling per frame.
      styled_cache = ctx.agent_ui.panel.cached_styled_messages
      pending_approval = ctx.shell_state.agent.pending_approval
      gui_messages = build_gui_messages(messages_with_ids, styled_cache, pending_approval)

      view = ctx.agent_ui.view
      help_visible = view.help_visible

      help_groups =
        if help_visible do
          Minga.Keymap.Scope.Agent.help_groups(view.focus)
        else
          []
        end

      panel = ctx.agent_ui.panel
      {cursor_line, cursor_col} = UIState.input_cursor(panel)
      vim_mode = ctx.editing.mode
      inner_width = max(ctx.viewport.cols - 10, 20)
      visible_rows = PromptSemanticWindow.visible_rows(panel, inner_width)
      prompt_completion = build_prompt_completion(panel)

      %{
        visible: true,
        messages: gui_messages,
        status: ctx.shell_state.agent.runtime.status || :idle,
        model: ctx.agent_ui.panel.model_name,
        prompt: prompt_text,
        pending_approval: nil,
        help_visible: help_visible,
        help_groups: help_groups,
        prompt_line_count: UIState.input_line_count(panel),
        prompt_cursor_line: cursor_line,
        prompt_cursor_col: cursor_col,
        prompt_vim_mode: vim_mode,
        prompt_visible_rows: visible_rows,
        prompt_completion: prompt_completion
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
  @spec build_gui_messages([{pos_integer(), term()}], [term()] | nil, map() | nil) :: [
          {pos_integer(), term()}
        ]
  defp build_gui_messages(messages_with_ids, nil, pending_approval) do
    Enum.map(messages_with_ids, &maybe_inline_approval(&1, pending_approval))
  end

  defp build_gui_messages(messages_with_ids, styled_cache, pending_approval)
       when is_list(styled_cache) do
    # Pad the cache to match message length if needed (messages may have grown)
    padded = pad_cache(styled_cache, length(messages_with_ids))

    Enum.zip(messages_with_ids, padded)
    |> Enum.map(&maybe_style_message(&1, pending_approval))
  end

  @spec maybe_style_message({{pos_integer(), term()}, term()}, map() | nil) ::
          {pos_integer(), term()}
  defp maybe_style_message({{id, {:assistant, _text} = msg}, nil}, _pending_approval),
    do: {id, msg}

  defp maybe_style_message({{id, {:assistant, _text}}, styled_lines}, _pending_approval),
    do: {id, {:styled_assistant, styled_lines}}

  defp maybe_style_message({{id, {:tool_call, tc} = msg}, styled_lines}, pending_approval) do
    case maybe_inline_approval({id, msg}, pending_approval) do
      {^id, {:approval_tool_call, _tc, _approval}} = approval_message ->
        approval_message

      {^id, {:tool_call, _tc}} when is_list(styled_lines) ->
        {id, {:styled_tool_call, tc, styled_lines}}

      unchanged ->
        unchanged
    end
  end

  defp maybe_style_message({{id, msg}, _cache_entry}, _pending_approval), do: {id, msg}

  @spec maybe_inline_approval({pos_integer(), term()}, map() | nil) :: {pos_integer(), term()}
  defp maybe_inline_approval({id, {:tool_call, tc}}, %{tool_call_id: tool_call_id} = approval)
       when tc.id == tool_call_id do
    {id, {:approval_tool_call, tc, approval}}
  end

  defp maybe_inline_approval({id, msg}, _pending_approval), do: {id, msg}

  @spec pad_cache([term()], non_neg_integer()) :: [term()]
  defp pad_cache(cache, target_len) when length(cache) >= target_len, do: cache
  defp pad_cache(cache, target_len), do: cache ++ List.duplicate(nil, target_len - length(cache))

  # ── Gutter separator ──

  @spec build_gui_gutter_separator_commands(ctx()) :: [binary()]
  defp build_gui_gutter_separator_commands(ctx) do
    show? = Config.get(:show_gutter_separator)
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    gutter_w = if active_window, do: active_window.render_cache.last_gutter_w, else: 0

    # Only send separator when enabled, visible gutter (gutter_w > 0).
    # Use the theme's gutter separator color, falling back to gutter fg.
    # Theme colors are already 24-bit RGB integers.
    {col, color_rgb} =
      if show? and gutter_w > 0 do
        color = ctx.theme.gutter.separator_fg || ctx.theme.gutter.fg
        {gutter_w, color}
      else
        {0, 0}
      end

    [ProtocolGUI.encode_gui_gutter_separator(max(col, 0), color_rgb)]
  end

  # ── Cursorline ──

  @spec build_gui_cursorline_commands(ctx()) :: [binary()]
  defp build_gui_cursorline_commands(ctx) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    cursorline_enabled = Config.get(:cursorline)

    {row, bg_rgb} =
      if active_window && cursorline_enabled do
        # Compute screen row of cursor: content_rect row + (cursor_line - viewport_top)
        layout = ctx.layout

        case Map.get(layout.window_layouts, ctx.windows.active) do
          %{content: {content_row, _col, _w, _h}} ->
            cursor_line = active_window.render_cache.last_cursor_line || 0
            viewport_top = active_window.render_cache.last_viewport_top || 0
            screen_row = content_row + cursor_line - viewport_top
            bg = ctx.theme.editor.cursorline_bg || 0
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

  @spec build_gui_gutter_commands(ctx()) :: [binary()]
  defp build_gui_gutter_commands(ctx) do
    layout = ctx.layout

    window_gutters =
      Enum.flat_map(layout.window_layouts, fn {win_id, win_layout} ->
        window = Map.get(ctx.windows.map, win_id)

        # Skip agent chat windows (they don't have gutter)
        if window && is_pid(window.buffer) && !Content.agent_chat?(window.content) do
          is_active = win_id == ctx.windows.active
          gutter_data = build_window_gutter(window, win_id, win_layout, is_active)
          [ProtocolGUI.encode_gui_gutter(gutter_data)]
        else
          []
        end
      end)

    window_gutters
  end

  # Builds a minimal gutter entry for the agent prompt SemanticWindow.
  # Positions it at the bottom of the grid with no line numbers or sign column.
  @spec build_window_gutter(
          MingaEditor.Window.t(),
          pos_integer(),
          Layout.window_layout(),
          boolean()
        ) :: ProtocolGUI.gutter_data()
  defp build_window_gutter(window, win_id, win_layout, is_active) do
    buf = window.buffer
    cursor_line = max(window.render_cache.last_cursor_line, 0)
    viewport_top = max(window.render_cache.last_viewport_top, 0)
    line_count = max(window.render_cache.last_line_count, 0)

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
      build_gutter_entries(window, buf, win_pos, %{
        cursor_line: cursor_line,
        viewport_top: viewport_top,
        line_count: line_count
      })
    end
  end

  @spec build_gutter_entries(MingaEditor.Window.t(), pid(), map(), map()) ::
          ProtocolGUI.gutter_data()
  defp build_gutter_entries(window, buf, win_pos, params) do
    %{cursor_line: cursor_line, viewport_top: viewport_top, line_count: line_count} = params
    line_number_style = Buffer.get_option(buf, :line_numbers)

    # Sign column is always reserved for consistent gutter layout.
    sign_col_width = MingaEditor.Renderer.Gutter.sign_column_width()

    line_number_width =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    # Get signs and decorations for the buffer
    decorations = Buffer.decorations(buf)
    diag_signs = ContentHelpers.diagnostic_signs_for_window(window)
    git_signs = ContentHelpers.git_signs_for_window(window)

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
          Minga.Core.Decorations.t()
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
  @spec resolve_annotation_entry(non_neg_integer(), Minga.Core.Decorations.t()) ::
          ProtocolGUI.gutter_entry()
  defp resolve_annotation_entry(buf_line, decorations) do
    icons =
      decorations
      |> Minga.Core.Decorations.annotations_for_line(buf_line)
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

  @spec build_gui_hover_popup_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_hover_popup_cmd(%{shell_state: %{hover_popup: popup}}, caches) do
    fp = :erlang.phash2(popup)

    if fp != caches.last_gui_hover_popup_fp do
      {ProtocolGUI.encode_gui_hover_popup(popup), %{caches | last_gui_hover_popup_fp: fp}}
    else
      {nil, caches}
    end
  end

  # ── Signature help ──

  @spec build_gui_signature_help_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_signature_help_cmd(%{shell_state: %{signature_help: sh}}, caches) do
    fp = :erlang.phash2(sh)

    if fp != caches.last_gui_signature_help_fp do
      {ProtocolGUI.encode_gui_signature_help(sh), %{caches | last_gui_signature_help_fp: fp}}
    else
      {nil, caches}
    end
  end

  # ── Split separators ──

  @spec build_gui_split_separator_commands(ctx()) :: [binary()]
  defp build_gui_split_separator_commands(ctx) do
    if MingaEditor.State.Windows.split?(ctx.windows) do
      layout = ctx.layout
      border_color = ctx.theme.editor.split_border_fg

      # Collect vertical separators from the window tree
      verticals =
        ChromeHelpers.collect_vertical_separators(
          ctx.windows.tree,
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

  @spec build_gui_float_popup_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_float_popup_cmd(ctx, caches) do
    float_window = find_float_popup_window(ctx)

    fp = float_popup_fingerprint(ctx, float_window)

    if fp != caches.last_gui_float_popup_fp do
      cmd =
        if float_window do
          data = build_float_popup_data(ctx, float_window)
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

      {cmd, %{caches | last_gui_float_popup_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec float_popup_fingerprint(ctx(), MingaEditor.Window.t() | nil) :: integer()
  defp float_popup_fingerprint(_ctx, nil), do: :erlang.phash2(nil)

  defp float_popup_fingerprint(ctx, window) do
    rule = window.popup_meta.rule
    vp = ctx.viewport
    width = resolve_float_dim(rule, :width, vp.cols)
    height = resolve_float_dim(rule, :height, vp.rows)

    buffer_fp =
      try do
        {Buffer.buffer_name(window.buffer), Buffer.version(window.buffer)}
      catch
        :exit, _ -> :dead
      end

    :erlang.phash2({window.buffer, window.popup_meta, width, height, buffer_fp})
  end

  @spec find_float_popup_window(ctx()) :: MingaEditor.Window.t() | nil
  defp find_float_popup_window(ctx) do
    Enum.find_value(ctx.windows.map, fn
      {_id,
       %{
         popup_meta: %MingaEditor.UI.Popup.Active{
           rule: %Minga.Popup.Rule{display: :float}
         }
       } = w} ->
        w

      _ ->
        nil
    end)
  end

  @spec build_float_popup_data(ctx(), MingaEditor.Window.t()) :: ProtocolGUI.float_popup_data()
  defp build_float_popup_data(ctx, window) do
    rule = window.popup_meta.rule
    vp = ctx.viewport

    width = resolve_float_dim(rule, :width, vp.cols)
    height = resolve_float_dim(rule, :height, vp.rows)

    # Interior dimensions (subtract 2 for border)
    interior_h = max(height - 2, 1)
    interior_w = max(width - 2, 1)

    {title, lines} =
      try do
        name = Buffer.buffer_name(window.buffer)
        snapshot = Buffer.render_snapshot(window.buffer, 0, interior_h)
        trimmed = Enum.map(snapshot.lines, &String.slice(&1, 0, interior_w))
        {name, trimmed}
      catch
        :exit, _ -> {"", []}
      end

    %{visible: true, title: title, lines: lines, width: width, height: height}
  end

  @spec resolve_float_dim(Minga.Popup.Rule.t(), :width | :height, pos_integer()) ::
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

  # Bottom panel is special: it returns {cmd | nil, updated_ctx, updated_caches} because
  # encode_gui_bottom_panel may advance the message_store cursor when new
  # entries have arrived. We still fingerprint to skip encoding when the
  # panel hasn't changed.
  @spec build_gui_bottom_panel_cmd(ctx(), Caches.t()) :: {binary() | nil, ctx(), Caches.t()}
  defp build_gui_bottom_panel_cmd(
         %{shell_state: %{bottom_panel: panel}, message_store: store} = ctx,
         caches
       ) do
    fp = :erlang.phash2({panel, store})

    if fp != caches.last_gui_bottom_panel_fp do
      {cmd, new_store} = ProtocolGUI.encode_gui_bottom_panel(panel, store)
      {cmd, %{ctx | message_store: new_store}, %{caches | last_gui_bottom_panel_fp: fp}}
    else
      {nil, ctx, caches}
    end
  end

  # ── Board ──

  @spec build_gui_board_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_board_cmd(%{shell: MingaEditor.Shell.Board, shell_state: board}, caches) do
    # Always send when Board is active so the GUI stays in sync.
    # The fingerprint covers card count, focused card, zoom state, and
    # card statuses so we skip encoding when nothing changed.
    fp = board_fingerprint(board)

    if fp != caches.last_gui_board_fp do
      {ProtocolGUI.encode_gui_board(board), %{caches | last_gui_board_fp: fp}}
    else
      {nil, caches}
    end
  end

  # Board not active: send visible=false once to dismiss.
  # Must NOT use a default Board.State (grid_view? returns true → visible=1).
  # Instead, build a minimal board with zoomed_into set so visible encodes as 0.
  defp build_gui_board_cmd(_ctx, caches) do
    if caches.last_gui_board_fp != :dismissed do
      # zoomed_into: 1 forces grid_view? → false → visible=0
      dismissed = %MingaEditor.Shell.Board.State{zoomed_into: 1}
      {ProtocolGUI.encode_gui_board(dismissed), %{caches | last_gui_board_fp: :dismissed}}
    else
      {nil, caches}
    end
  end

  @spec board_fingerprint(MingaEditor.Shell.Board.State.t()) :: integer()
  defp board_fingerprint(board) do
    cards =
      board
      |> MingaEditor.Shell.Board.State.sorted_cards()
      |> Enum.map(fn card ->
        {card.id, card.status, card.kind, card.task, card.model, card.created_at,
         card.recent_files, card.sparkline}
      end)

    :erlang.phash2({
      board.focused_card,
      board.zoomed_into,
      board.filter_mode,
      board.filter_text,
      cards
    })
  end

  # ── Agent context bar ──

  @spec build_gui_agent_context_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp build_gui_agent_context_cmd(
         %{shell: MingaEditor.Shell.Board, shell_state: %{zoomed_into: nil}},
         caches
       ) do
    send_hide_if_needed(:hidden, caches)
  end

  defp build_gui_agent_context_cmd(%{shell: MingaEditor.Shell.Board, shell_state: board}, caches) do
    card = MingaEditor.Shell.Board.State.zoomed(board)
    send_agent_context_if_applicable(board.zoomed_into, card, caches)
  end

  # Not Board shell: hide context bar
  defp build_gui_agent_context_cmd(_state, caches) do
    send_hide_if_needed(:not_board, caches)
  end

  @spec send_hide_if_needed(atom(), Caches.t()) :: {binary() | nil, Caches.t()}
  defp send_hide_if_needed(fp_key, caches) do
    if caches.last_gui_agent_context_fp != fp_key do
      {encode_hidden_agent_context(), %{caches | last_gui_agent_context_fp: fp_key}}
    else
      {nil, caches}
    end
  end

  @spec send_agent_context_if_applicable(
          pos_integer(),
          MingaEditor.Shell.Board.Card.t() | nil,
          Caches.t()
        ) :: {binary() | nil, Caches.t()}
  defp send_agent_context_if_applicable(card_id, card, caches)
       when is_map(card) and not is_nil(card) do
    if MingaEditor.Shell.Board.Card.you_card?(card) do
      send_hide_if_needed(:you_card, caches)
    else
      send_agent_context_for_card(card_id, card, caches)
    end
  end

  defp send_agent_context_if_applicable(_card_id, _card, caches) do
    send_hide_if_needed(:you_card, caches)
  end

  @spec send_agent_context_for_card(
          pos_integer(),
          MingaEditor.Shell.Board.Card.t(),
          Caches.t()
        ) :: {binary() | nil, Caches.t()}
  defp send_agent_context_for_card(card_id, card, caches) do
    can_approve = card.status in [:needs_you, :done]
    fp = :erlang.phash2({card_id, card.task, card.created_at, card.status, can_approve})

    if fp != caches.last_gui_agent_context_fp do
      cmd =
        ProtocolGUI.encode_gui_agent_context(
          true,
          card.task,
          card.created_at,
          card.status,
          can_approve
        )

      {cmd, %{caches | last_gui_agent_context_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_hidden_agent_context() :: binary()
  defp encode_hidden_agent_context do
    ProtocolGUI.encode_gui_agent_context(false, "", DateTime.utc_now(), :idle, false)
  end

  # ── Change Summary ──

  @spec build_gui_change_summary_cmd(ctx(), Caches.t()) :: {binary() | nil, Caches.t()}

  # Change summary visible when zoomed into an agent card (not You card)
  defp build_gui_change_summary_cmd(
         %{shell: MingaEditor.Shell.Board, shell_state: %{zoomed_into: card_id}} = _ctx,
         caches
       )
       when card_id != nil do
    # TODO: Compute diff stats from the card's touched files
    # For now, send empty list to test the UI
    entries = []
    selected_index = 0

    fp = :erlang.phash2({card_id, entries})

    if fp != caches.last_gui_change_summary_fp do
      {ProtocolGUI.encode_gui_change_summary(entries, selected_index),
       %{caches | last_gui_change_summary_fp: fp}}
    else
      {nil, caches}
    end
  end

  # Board grid or other shells: hide change summary
  defp build_gui_change_summary_cmd(_ctx, caches) do
    if caches.last_gui_change_summary_fp != :hidden do
      {ProtocolGUI.encode_gui_change_summary([], 0),
       %{caches | last_gui_change_summary_fp: :hidden}}
    else
      {nil, caches}
    end
  end

  # ── Indent guides ──

  @spec build_gui_indent_guide_commands(ctx()) :: [binary()]
  defp build_gui_indent_guide_commands(ctx) do
    indent_guides_enabled? =
      try do
        Config.get(:indent_guides)
      catch
        :exit, _ -> true
      end

    if indent_guides_enabled? do
      layout = ctx.layout
      windows = ctx.windows.map

      Enum.flat_map(layout.window_layouts, fn {win_id, win_layout} ->
        build_indent_guide_for_window(Map.get(windows, win_id), win_id, win_layout)
      end)
    else
      []
    end
  end

  @spec build_indent_guide_for_window(
          MingaEditor.Window.t() | nil,
          pos_integer(),
          Layout.window_layout()
        ) ::
          [binary()]
  defp build_indent_guide_for_window(nil, win_id, _layout), do: return_empty_guides(win_id)

  defp build_indent_guide_for_window(window, win_id, win_layout) do
    if is_pid(window.buffer) && !Content.agent_chat?(window.content) do
      {_cr, _cc, _cw, content_height} = win_layout.content
      build_window_indent_guides(window, win_id, content_height)
    else
      return_empty_guides(win_id)
    end
  end

  @spec build_window_indent_guides(MingaEditor.Window.t(), pos_integer(), non_neg_integer()) ::
          [binary()]
  defp build_window_indent_guides(window, win_id, content_height) do
    buf = window.buffer
    viewport_top = max(window.render_cache.last_viewport_top, 0)
    line_count = max(window.render_cache.last_line_count, 0)
    visible_count = min(content_height, max(line_count - viewport_top, 0))

    if visible_count <= 0 or line_count == 0 do
      return_empty_guides(win_id)
    else
      compute_and_encode_guides(window, win_id, buf, viewport_top, visible_count)
    end
  end

  @spec compute_and_encode_guides(
          MingaEditor.Window.t(),
          pos_integer(),
          pid(),
          non_neg_integer(),
          pos_integer()
        ) ::
          [binary()]
  defp compute_and_encode_guides(window, win_id, buf, viewport_top, visible_count) do
    {_cursor_line, cursor_col} = window.cursor

    tab_width =
      try do
        Buffer.get_option(buf, :tab_width)
      catch
        :exit, _ -> 2
      end

    lines =
      try do
        Buffer.Server.get_lines(buf, viewport_top, visible_count)
      catch
        :exit, _ -> []
      end

    {guides, indent_levels} =
      Minga.Core.IndentGuide.compute_with_levels(lines, tab_width, cursor_col)

    encode_guides(guides, win_id, tab_width, indent_levels)
  end

  @spec encode_guides(
          [Minga.Core.IndentGuide.guide()],
          pos_integer(),
          pos_integer(),
          [non_neg_integer()]
        ) ::
          [binary()]
  defp encode_guides([], win_id, _tab_width, _indent_levels), do: return_empty_guides(win_id)

  defp encode_guides(guides, win_id, tab_width, indent_levels) do
    active_guide = Enum.find(guides, fn g -> g.active end)
    active_col = if active_guide, do: active_guide.col, else: 0xFFFF

    guide_data = %{
      window_id: win_id,
      tab_width: tab_width,
      active_guide_col: active_col,
      guide_cols: Enum.map(guides, & &1.col),
      line_indent_levels: indent_levels
    }

    [ProtocolGUI.encode_gui_indent_guides(guide_data)]
  end

  @spec return_empty_guides(pos_integer()) :: [binary()]
  defp return_empty_guides(win_id), do: [ProtocolGUI.encode_gui_indent_guides_empty(win_id)]
end
