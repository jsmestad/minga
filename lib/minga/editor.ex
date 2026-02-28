defmodule Minga.Editor do
  @moduledoc """
  Editor orchestration GenServer.

  Ties together the buffer, port manager, viewport, and modal FSM. Receives
  input events from the Port Manager, routes them through `Minga.Mode.process/3`,
  executes the resulting commands against the buffer, recomputes the visible
  region, and sends render commands back to the Zig renderer.

  The editor starts in **Normal mode** (Vim-style). The status line reflects
  the current mode: `-- NORMAL --`, `-- INSERT --`, etc.
  """

  use GenServer

  alias Minga.Buffer.GapBuffer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Mode.CommandState
  alias Minga.Mode.VisualState
  alias Minga.Picker
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol
  alias Minga.TextObject
  alias Minga.WhichKey

  require Logger

  import Bitwise

  @ctrl Protocol.mod_ctrl()

  @typedoc "Options for starting the editor."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:port_manager, GenServer.server()}
          | {:buffer, pid()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}

  alias Minga.Editor.State, as: EditorState

  @typedoc "Internal state."
  @type state :: EditorState.t()

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the editor."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Opens a file in the editor."
  @spec open_file(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def open_file(server \\ __MODULE__, file_path) when is_binary(file_path) do
    GenServer.call(server, {:open_file, file_path})
  end

  @doc "Triggers a full re-render of the current state."
  @spec render(GenServer.server()) :: :ok
  def render(server \\ __MODULE__) do
    GenServer.cast(server, :render)
  end

  # ── Server Callbacks ─────────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    port_manager = Keyword.get(opts, :port_manager, PortManager)
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    buffer = Keyword.get(opts, :buffer)

    unless is_nil(port_manager) do
      try do
        PortManager.subscribe(port_manager)
      catch
        :exit, _ -> Logger.warning("Could not subscribe to port manager")
      end
    end

    buffers = if buffer, do: [buffer], else: []

    state = %EditorState{
      buffer: buffer,
      buffers: buffers,
      active_buffer: 0,
      port_manager: port_manager,
      viewport: Viewport.new(height, width),
      mode: :normal,
      mode_state: Mode.initial_state()
    }

    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:open_file, file_path}, _from, state) do
    case start_buffer(file_path) do
      {:ok, pid} ->
        new_state = add_buffer(state, pid)
        do_render(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast(:render, state) do
    do_render(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:minga_input, {:ready, width, height}}, state) do
    new_state = %{state | viewport: Viewport.new(height, width)}
    do_render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:resize, width, height}}, state) do
    new_state = %{state | viewport: Viewport.new(height, width)}
    do_render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, %{picker: picker} = state)
       when not is_nil(picker) do
    new_state = handle_picker_key(state, codepoint, modifiers)
    do_render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:minga_input, {:key_press, codepoint, modifiers}}, state) do
    new_state = handle_key(state, codepoint, modifiers)
    do_render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, ref}, %{whichkey_timer: ref} = state) do
    new_state = %{state | show_whichkey: true}
    do_render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:whichkey_timeout, _ref}, state) do
    # Stale timer — ignore.
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Key dispatch ─────────────────────────────────────────────────────────────

  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: state()

  # Global bindings — processed before the Mode FSM.
  # Ctrl+S → save (works in any mode).
  defp handle_key(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.buffer do
      case BufferServer.save(state.buffer) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Save failed: #{inspect(reason)}")
      end
    end

    state
  end

  # Ctrl+Q → quit (works in any mode).
  defp handle_key(state, ?q, mods) when band(mods, @ctrl) != 0 do
    System.stop(0)
    state
  end

  # All other keys go through the Mode FSM.
  defp handle_key(state, codepoint, modifiers) do
    key = {codepoint, modifiers}
    {new_mode, commands, new_mode_state} = Mode.process(state.mode, key, state.mode_state)

    # When transitioning INTO visual mode, capture the current cursor as the
    # selection anchor. When transitioning INTO command mode, ensure we have
    # a CommandState.
    new_mode_state =
      cond do
        new_mode == :visual and state.mode != :visual and state.buffer ->
          anchor = BufferServer.cursor(state.buffer)
          %{new_mode_state | visual_anchor: anchor}

        new_mode == :command and state.mode != :command ->
          case new_mode_state do
            %CommandState{} -> new_mode_state
            _ -> %CommandState{}
          end

        true ->
          new_mode_state
      end

    base_state = %{state | mode: new_mode, mode_state: new_mode_state}

    # Clear any stale leader update from the process dictionary.
    Process.delete(:__leader_update__)

    after_commands =
      Enum.reduce(commands, base_state, fn cmd, acc ->
        execute_command(acc, cmd)
      end)

    # After commands have executed (they may need the old mode_state, e.g.
    # VisualState for delete_visual_selection), clean up the mode_state
    # if we've transitioned back to Normal from a different mode.
    after_commands =
      if new_mode == :normal and state.mode != :normal do
        case after_commands.mode_state do
          %Mode.State{} -> after_commands
          _ -> %{after_commands | mode_state: Mode.initial_state()}
        end
      else
        after_commands
      end

    # Apply any leader/whichkey state updates emitted by execute_command.
    case Process.delete(:__leader_update__) do
      nil ->
        after_commands

      updates ->
        Map.merge(after_commands, updates)
    end
  end

  # ── Command execution ────────────────────────────────────────────────────────

  @spec execute_command(state(), Mode.command()) :: state()
  defp execute_command(%{buffer: nil} = state, _cmd), do: state

  defp execute_command(%{buffer: buf} = state, :move_left) do
    BufferServer.move(buf, :left)
    state
  end

  defp execute_command(%{buffer: buf} = state, :move_right) do
    BufferServer.move(buf, :right)
    state
  end

  defp execute_command(%{buffer: buf} = state, :move_up) do
    BufferServer.move(buf, :up)
    state
  end

  defp execute_command(%{buffer: buf} = state, :move_down) do
    BufferServer.move(buf, :down)
    state
  end

  defp execute_command(%{buffer: buf} = state, :delete_before) do
    BufferServer.delete_before(buf)
    state
  end

  defp execute_command(%{buffer: buf} = state, :delete_at) do
    BufferServer.delete_at(buf)
    state
  end

  defp execute_command(%{buffer: buf} = state, :insert_newline) do
    BufferServer.insert_char(buf, "\n")
    state
  end

  defp execute_command(%{buffer: buf} = state, {:insert_char, char}) when is_binary(char) do
    BufferServer.insert_char(buf, char)
    state
  end

  defp execute_command(%{buffer: buf} = state, :move_to_line_start) do
    {line, _col} = BufferServer.cursor(buf)
    BufferServer.move_to(buf, {line, 0})
    state
  end

  defp execute_command(%{buffer: buf} = state, :move_to_line_end) do
    {line, _col} = BufferServer.cursor(buf)

    end_col =
      case BufferServer.get_lines(buf, line, 1) do
        [text] -> max(0, String.length(text) - 1)
        [] -> 0
      end

    BufferServer.move_to(buf, {line, end_col})
    state
  end

  defp execute_command(%{buffer: buf} = state, :insert_line_below) do
    {line, _col} = BufferServer.cursor(buf)

    end_col =
      case BufferServer.get_lines(buf, line, 1) do
        [text] -> String.length(text)
        [] -> 0
      end

    BufferServer.move_to(buf, {line, end_col})
    BufferServer.insert_char(buf, "\n")
    state
  end

  defp execute_command(%{buffer: buf} = state, :insert_line_above) do
    {line, _col} = BufferServer.cursor(buf)
    BufferServer.move_to(buf, {line, 0})
    BufferServer.insert_char(buf, "\n")
    BufferServer.move(buf, :up)
    state
  end

  defp execute_command(%{buffer: buf} = state, :save) do
    case BufferServer.save(buf) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Save failed: #{inspect(reason)}")
    end

    state
  end

  defp execute_command(state, :quit) do
    System.stop(0)
    state
  end

  # ── Page / half-page scrolling ────────────────────────────────────────────────

  defp execute_command(%{buffer: buf, viewport: vp} = state, :half_page_down) do
    page_move(buf, vp, div(Viewport.content_rows(vp), 2))
    state
  end

  defp execute_command(%{buffer: buf, viewport: vp} = state, :half_page_up) do
    page_move(buf, vp, -div(Viewport.content_rows(vp), 2))
    state
  end

  defp execute_command(%{buffer: buf, viewport: vp} = state, :page_down) do
    page_move(buf, vp, Viewport.content_rows(vp))
    state
  end

  defp execute_command(%{buffer: buf, viewport: vp} = state, :page_up) do
    page_move(buf, vp, -Viewport.content_rows(vp))
    state
  end

  # ── Undo / redo ──────────────────────────────────────────────────────────────

  defp execute_command(%{buffer: buf} = state, :undo) do
    BufferServer.undo(buf)
    state
  end

  defp execute_command(%{buffer: buf} = state, :redo) do
    BufferServer.redo(buf)
    state
  end

  # ── Paste ─────────────────────────────────────────────────────────────────────

  defp execute_command(%{buffer: buf, register: text} = state, :paste_before)
       when is_binary(text) do
    BufferServer.insert_char(buf, text)
    state
  end

  defp execute_command(state, :paste_before), do: state

  defp execute_command(%{buffer: buf, register: text} = state, :paste_after)
       when is_binary(text) do
    BufferServer.move(buf, :right)
    BufferServer.insert_char(buf, text)
    state
  end

  defp execute_command(state, :paste_after), do: state

  # ── Line-wise operator commands (dd / yy) ────────────────────────────────────

  defp execute_command(%{buffer: buf} = state, :delete_line) do
    {line, _col} = BufferServer.cursor(buf)
    yanked = BufferServer.get_lines_content(buf, line, line)
    BufferServer.delete_lines(buf, line, line)
    %{state | register: yanked <> "\n"}
  end

  defp execute_command(%{buffer: buf} = state, :yank_line) do
    {line, _col} = BufferServer.cursor(buf)
    yanked = BufferServer.get_lines_content(buf, line, line)
    %{state | register: yanked <> "\n"}
  end

  # ── Ex command (from : command line) ────────────────────────────────────────

  defp execute_command(state, {:execute_ex_command, {:save, []}}) do
    execute_command(state, :save)
  end

  defp execute_command(state, {:execute_ex_command, {:quit, []}}) do
    execute_command(state, :quit)
  end

  defp execute_command(state, {:execute_ex_command, {:force_quit, []}}) do
    Logger.debug("Force quitting editor")
    System.stop(0)
    state
  end

  defp execute_command(state, {:execute_ex_command, {:save_quit, []}}) do
    state_after_save = execute_command(state, :save)
    Logger.debug("Quitting editor after save")
    System.stop(0)
    state_after_save
  end

  defp execute_command(state, {:execute_ex_command, {:edit, file_path}}) do
    # Check if the file is already open in a buffer
    case find_buffer_by_path(state, file_path) do
      nil ->
        # Open a new buffer for this file
        case start_buffer(file_path) do
          {:ok, pid} ->
            add_buffer(state, pid)

          {:error, reason} ->
            Logger.error("Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        # Switch to existing buffer
        switch_to_buffer(state, idx)
    end
  end

  defp execute_command(%{buffer: buf} = state, {:execute_ex_command, {:goto_line, line_num}}) do
    target_line = max(0, line_num - 1)
    BufferServer.move_to(buf, {target_line, 0})
    state
  end

  defp execute_command(state, {:execute_ex_command, {:unknown, raw}}) do
    Logger.debug("Unknown ex command: #{raw}")
    state
  end

  defp execute_command(
         %{buffer: buf, mode_state: %VisualState{} = ms} = state,
         :delete_visual_selection
       ) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = BufferServer.cursor(buf)

    yanked =
      case visual_type do
        :char ->
          text = BufferServer.get_range(buf, anchor, cursor)
          BufferServer.delete_range(buf, anchor, cursor)
          text

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          text = BufferServer.get_lines_content(buf, start_line, end_line)
          BufferServer.delete_lines(buf, start_line, end_line)
          text <> "\n"
      end

    %{state | register: yanked}
  end

  defp execute_command(
         %{buffer: buf, mode_state: %VisualState{} = ms} = state,
         :yank_visual_selection
       ) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = BufferServer.cursor(buf)

    yanked =
      case visual_type do
        :char ->
          BufferServer.get_range(buf, anchor, cursor)

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          BufferServer.get_lines_content(buf, start_line, end_line) <> "\n"
      end

    Logger.debug("Yanked visual selection")
    %{state | register: yanked}
  end

  # ── Leader / which-key commands ───────────────────────────────────────────

  defp execute_command(state, {:leader_start, node}) do
    if state.whichkey_timer, do: WhichKey.cancel_timeout(state.whichkey_timer)
    timer = WhichKey.start_timeout()
    # Side-channel: whichkey updates are merged after the reduce completes.
    Process.put(:__leader_update__, %{
      whichkey_node: node,
      whichkey_timer: timer,
      show_whichkey: false
    })

    state
  end

  defp execute_command(state, {:leader_progress, node}) do
    if state.whichkey_timer, do: WhichKey.cancel_timeout(state.whichkey_timer)
    timer = WhichKey.start_timeout()

    Process.put(:__leader_update__, %{
      whichkey_node: node,
      whichkey_timer: timer,
      show_whichkey: state.show_whichkey
    })

    state
  end

  defp execute_command(state, :leader_cancel) do
    if state.whichkey_timer, do: WhichKey.cancel_timeout(state.whichkey_timer)

    Process.put(:__leader_update__, %{
      whichkey_node: nil,
      whichkey_timer: nil,
      show_whichkey: false
    })

    state
  end

  # ── Text object commands ───────────────────────────────────────────────────

  defp execute_command(%{buffer: buf} = state, {:delete_text_object, modifier, spec})
       when not is_nil(buf) do
    apply_text_object(state, modifier, spec, :delete)
  end

  defp execute_command(%{buffer: buf} = state, {:change_text_object, modifier, spec})
       when not is_nil(buf) do
    apply_text_object(state, modifier, spec, :delete)
  end

  defp execute_command(%{buffer: buf} = state, {:yank_text_object, modifier, spec})
       when not is_nil(buf) do
    apply_text_object(state, modifier, spec, :yank)
  end

  # Stub leader-bound commands — logged for discoverability, not yet implemented.
  defp execute_command(state, :find_file) do
    Logger.debug("find_file: not yet implemented")
    state
  end

  defp execute_command(state, :buffer_list) do
    open_buffer_picker(state)
  end

  defp execute_command(state, :buffer_next) do
    next_buffer(state)
  end

  defp execute_command(state, :buffer_prev) do
    prev_buffer(state)
  end

  defp execute_command(state, :kill_buffer) do
    remove_current_buffer(state)
  end

  defp execute_command(state, :window_left), do: state
  defp execute_command(state, :window_right), do: state
  defp execute_command(state, :window_up), do: state
  defp execute_command(state, :window_down), do: state
  defp execute_command(state, :split_vertical), do: state
  defp execute_command(state, :split_horizontal), do: state
  defp execute_command(state, :describe_key), do: state

  # Unknown or unimplemented commands are silently ignored.
  defp execute_command(state, _cmd), do: state

  # ── Rendering ────────────────────────────────────────────────────────────────

  @spec do_render(state()) :: :ok
  defp do_render(%{buffer: nil} = state) do
    commands = [
      Protocol.encode_clear(),
      Protocol.encode_draw(0, 0, "Minga v#{Minga.version()} — No file open"),
      Protocol.encode_draw(1, 0, "Use: mix minga <filename>"),
      Protocol.encode_cursor(0, 0),
      Protocol.encode_batch_end()
    ]

    PortManager.send_commands(state.port_manager, commands)
  end

  defp do_render(state) do
    cursor = BufferServer.cursor(state.buffer)
    viewport = Viewport.scroll_to_cursor(state.viewport, cursor)
    {first_line, _last_line} = Viewport.visible_range(viewport)
    visible_rows = Viewport.content_rows(viewport)
    lines = BufferServer.get_lines(state.buffer, first_line, visible_rows)

    clear = [Protocol.encode_clear()]

    visual_selection = visual_selection_bounds(state, cursor)

    line_commands =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line_text, screen_row} ->
        buf_line = first_line + screen_row
        render_line(line_text, screen_row, buf_line, viewport, visual_selection)
      end)

    tilde_commands =
      if length(lines) < visible_rows do
        for row <- length(lines)..(visible_rows - 1) do
          Protocol.encode_draw(row, 0, "~", fg: 0x555555)
        end
      else
        []
      end

    # ── Modeline (row N-2) — Doom Emacs-style colored segments ──
    {cursor_line, cursor_col} = cursor
    file_name =
      case BufferServer.file_path(state.buffer) do
        nil -> "[scratch]"
        path -> Path.basename(path)
      end
    dirty_marker = if BufferServer.dirty?(state.buffer), do: " ● ", else: ""
    line_count = BufferServer.line_count(state.buffer)
    buf_count = length(state.buffers)
    buf_index = state.active_buffer + 1
    modeline_row = viewport.rows - 2

    modeline_commands = render_modeline(
      modeline_row,
      viewport.cols,
      state.mode,
      state.mode_state,
      file_name,
      dirty_marker,
      cursor_line,
      cursor_col,
      line_count,
      buf_index,
      buf_count
    )

    # ── Minibuffer (row N-1) — command input or messages ──
    minibuffer_row = viewport.rows - 1

    minibuffer_command =
      case state.mode do
        :command ->
          cmd_text = ":" <> state.mode_state.input
          Protocol.encode_draw(
            minibuffer_row,
            0,
            String.pad_trailing(cmd_text, viewport.cols),
            fg: 0xEEEEEE,
            bg: 0x000000
          )

        _ ->
          # Empty minibuffer when not in command mode
          Protocol.encode_draw(
            minibuffer_row,
            0,
            String.duplicate(" ", viewport.cols),
            fg: 0x888888,
            bg: 0x000000
          )
      end

    # ── Picker overlay (when active, replaces minibuffer + overlays content) ──
    {picker_commands, picker_cursor} = maybe_render_picker(state, viewport)

    # ── Cursor placement + shape ──
    cursor_shape_command =
      if state.picker do
        Protocol.encode_cursor_shape(:beam)
      else
        Protocol.encode_cursor_shape(cursor_shape_for_mode(state.mode))
      end

    cursor_command =
      cond do
        picker_cursor != nil ->
          {row, col} = picker_cursor
          Protocol.encode_cursor(row, col)

        state.mode == :command ->
          cmd_col = String.length(state.mode_state.input) + 1
          Protocol.encode_cursor(minibuffer_row, cmd_col)

        true ->
          cursor_row = cursor_line - viewport.top
          cursor_col_screen = cursor_col - viewport.left
          Protocol.encode_cursor(cursor_row, cursor_col_screen)
      end

    whichkey_commands = maybe_render_whichkey(state, viewport)

    all_commands =
      clear ++
        line_commands ++
        tilde_commands ++
        modeline_commands ++
        [minibuffer_command] ++
        whichkey_commands ++
        picker_commands ++
        [cursor_shape_command, cursor_command, Protocol.encode_batch_end()]

    PortManager.send_commands(state.port_manager, all_commands)
    :ok
  end

  @spec maybe_render_whichkey(state(), Viewport.t()) :: [binary()]
  defp maybe_render_whichkey(%{show_whichkey: true, whichkey_node: node}, viewport)
       when not is_nil(node) do
    bindings = WhichKey.bindings_from_node(node)
    lines = WhichKey.render_popup(bindings)

    popup_row = max(0, viewport.rows - 3 - length(lines))

    ([Protocol.encode_draw(popup_row, 0, String.duplicate("─", viewport.cols), fg: 0x888888)] ++
       lines)
    |> Enum.with_index(popup_row + 1)
    |> Enum.map(fn {line_text, row} ->
      padded = String.pad_trailing(line_text, viewport.cols)
      Protocol.encode_draw(row, 0, padded, fg: 0xEEEEEE, bg: 0x333333)
    end)
  end

  defp maybe_render_whichkey(_state, _viewport), do: []

  # ── Picker rendering ────────────────────────────────────────────────────────

  @spec maybe_render_picker(state(), Viewport.t()) ::
          {[binary()], {non_neg_integer(), non_neg_integer()} | nil}
  defp maybe_render_picker(%{picker: nil}, _viewport), do: {[], nil}

  defp maybe_render_picker(%{picker: picker}, viewport) do
    {visible, selected_offset} = Picker.visible_items(picker)
    item_count = length(visible)

    # Layout: items grow upward from row N-2, prompt on row N-1
    prompt_row = viewport.rows - 1
    separator_row = prompt_row - item_count - 1
    first_item_row = separator_row + 1

    # Background colors
    bg = 0x1E2127
    sel_bg = 0x3E4451
    prompt_bg = 0x1E2127
    dim_fg = 0x5C6370
    text_fg = 0xABB2BF
    highlight_fg = 0xFFFFFF

    # Separator line
    title = picker.title
    filter_info = "#{Picker.count(picker)}/#{Picker.total(picker)}"
    sep_text = " #{title} " <> String.duplicate("─", max(0, viewport.cols - String.length(title) - String.length(filter_info) - 4)) <> " #{filter_info} "
    separator_cmd =
      if separator_row >= 0 do
        [Protocol.encode_draw(separator_row, 0,
          String.pad_trailing(sep_text, viewport.cols), fg: dim_fg, bg: bg)]
      else
        []
      end

    # Item rows
    item_commands =
      visible
      |> Enum.with_index()
      |> Enum.flat_map(fn {{_id, label, desc}, idx} ->
        row = first_item_row + idx
        if row < 0 or row >= viewport.rows do
          []
        else
          is_selected = idx == selected_offset
          fg = if is_selected, do: highlight_fg, else: text_fg
          row_bg = if is_selected, do: sel_bg, else: bg

          # Label on the left (bold for selected), description on the right (dimmed, truncated)
          label_text = " " <> label
          avail_for_desc = max(0, viewport.cols - String.length(label_text) - 2)
          desc_display = if desc != "" and avail_for_desc > 10,
            do: String.slice(desc, -min(avail_for_desc, String.length(desc)), avail_for_desc),
            else: ""

          row_text = label_text <>
            String.duplicate(" ", max(1, viewport.cols - String.length(label_text) - String.length(desc_display) - 1)) <>
            desc_display <> " "
          row_text = String.slice(row_text, 0, viewport.cols)

          label_cmd = Protocol.encode_draw(row, 0,
            String.pad_trailing(row_text, viewport.cols),
            fg: fg, bg: row_bg, bold: is_selected)

          if desc_display != "" do
            # Render description portion in dimmer color
            desc_start = viewport.cols - String.length(desc_display) - 1
            desc_cmd = Protocol.encode_draw(row, desc_start,
              desc_display, fg: dim_fg, bg: row_bg)
            [label_cmd, desc_cmd]
          else
            [label_cmd]
          end
        end
      end)

    # Prompt line (replaces minibuffer)
    prompt_text = "> " <> picker.query
    prompt_cmd = Protocol.encode_draw(
      prompt_row, 0,
      String.pad_trailing(prompt_text, viewport.cols),
      fg: highlight_fg, bg: prompt_bg
    )

    cursor_col = String.length(prompt_text)
    cursor_pos = {prompt_row, cursor_col}

    {separator_cmd ++ item_commands ++ [prompt_cmd], cursor_pos}
  end

  # ── Doom-style modeline ──────────────────────────────────────────────────────

  # Doom Emacs color palette for mode indicators
  @mode_colors %{
    normal:           {0x000000, 0x51AFEF},  # black on blue
    insert:           {0x000000, 0x98BE65},  # black on green
    visual:           {0x000000, 0xC678DD},  # black on magenta
    operator_pending: {0x000000, 0xDA8548},  # black on orange
    command:          {0x000000, 0xECBE7B}   # black on yellow
  }

  # Powerline separator characters
  @separator ""
  # @separator_thin ""

  @spec render_modeline(
          non_neg_integer(),
          pos_integer(),
          Mode.mode(),
          Mode.state(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: [binary()]
  defp render_modeline(row, cols, mode, mode_state, file_name, dirty_marker, cursor_line, cursor_col, line_count, buf_index, buf_count) do
    # Segment colors
    {mode_fg, mode_bg} = Map.get(@mode_colors, mode, {0x000000, 0x51AFEF})
    bar_fg = 0xBBC2CF
    bar_bg = 0x23272E
    info_fg = 0xBBC2CF
    info_bg = 0x3F444A

    # ── Left segments ──

    # 1. Mode badge
    mode_text = mode_badge(mode, mode_state)
    mode_segment = " #{mode_text} "

    # 2. Separator: mode → info
    sep1 = @separator

    # 3. File info segment (with buffer indicator when multiple buffers)
    buf_indicator = if buf_count > 1, do: " [#{buf_index}/#{buf_count}]", else: ""
    file_segment = " #{file_name}#{dirty_marker}#{buf_indicator} "

    # 4. Separator: info → bar
    sep2 = @separator

    # ── Right segments ──

    # Position info
    percent =
      if line_count <= 1,
        do: "Top",
        else: "#{div(cursor_line * 100, max(line_count - 1, 1))}%%"

    pos_segment = " #{cursor_line + 1}:#{cursor_col + 1} "
    pct_segment = " #{percent} "

    # Separator: bar → info (right side)
    sep3 = @separator
    # Separator: info → accent (right side)
    sep4 = @separator

    # ── Build draw commands ──
    # Left side
    left_col = 0
    commands = [
      Protocol.encode_draw(row, left_col, mode_segment, fg: mode_fg, bg: mode_bg, bold: true)
    ]
    left_col = left_col + String.length(mode_segment)

    commands = commands ++ [
      Protocol.encode_draw(row, left_col, sep1, fg: mode_bg, bg: info_bg)
    ]
    left_col = left_col + String.length(sep1)

    commands = commands ++ [
      Protocol.encode_draw(row, left_col, file_segment, fg: info_fg, bg: info_bg)
    ]
    left_col = left_col + String.length(file_segment)

    commands = commands ++ [
      Protocol.encode_draw(row, left_col, sep2, fg: info_bg, bg: bar_bg)
    ]
    left_col = left_col + String.length(sep2)

    # Fill middle with bar background
    right_total = String.length(sep3) + String.length(pos_segment) +
                  String.length(sep4) + String.length(pct_segment)
    fill_width = max(0, cols - left_col - right_total)
    fill = String.duplicate(" ", fill_width)

    commands = commands ++ [
      Protocol.encode_draw(row, left_col, fill, fg: bar_fg, bg: bar_bg)
    ]
    left_col = left_col + fill_width

    # Right side
    commands = commands ++ [
      Protocol.encode_draw(row, left_col, sep3, fg: info_bg, bg: bar_bg)
    ]
    left_col = left_col + String.length(sep3)

    commands = commands ++ [
      Protocol.encode_draw(row, left_col, pos_segment, fg: info_fg, bg: info_bg)
    ]
    left_col = left_col + String.length(pos_segment)

    commands = commands ++ [
      Protocol.encode_draw(row, left_col, sep4, fg: mode_bg, bg: info_bg)
    ]
    left_col = left_col + String.length(sep4)

    commands ++ [
      Protocol.encode_draw(row, left_col, pct_segment, fg: mode_fg, bg: mode_bg, bold: true)
    ]
  end

  @spec mode_badge(Mode.mode(), Mode.state()) :: String.t()
  defp mode_badge(:visual, %Minga.Mode.VisualState{visual_type: :line}), do: "V-LINE"
  defp mode_badge(:normal, _state), do: "NORMAL"
  defp mode_badge(:insert, _state), do: "INSERT"
  defp mode_badge(:visual, _state), do: "VISUAL"
  defp mode_badge(:operator_pending, _state), do: "OPERATOR"
  defp mode_badge(:command, _state), do: "COMMAND"

  @spec cursor_shape_for_mode(Mode.mode()) :: Protocol.cursor_shape()
  defp cursor_shape_for_mode(:insert), do: :beam
  defp cursor_shape_for_mode(_mode), do: :block

  # ── Private helpers ──────────────────────────────────────────────────────────

  # ── Text object execution helper ──────────────────────────────────────────

  @typedoc "How to apply a text object to the buffer."
  @type text_object_action :: :delete | :yank

  @spec apply_text_object(
          state(),
          Minga.Mode.OperatorPendingState.text_object_modifier(),
          term(),
          text_object_action()
        ) :: state()
  defp apply_text_object(%{buffer: buf} = state, modifier, spec, action) do
    cursor = BufferServer.cursor(buf)
    content = BufferServer.content(buf)
    tmp_buf = GapBuffer.new(content)

    range = compute_text_object_range(tmp_buf, cursor, modifier, spec)

    case {action, range} do
      {_, nil} ->
        state

      {:delete, {start_pos, end_pos}} ->
        text = BufferServer.get_range(buf, start_pos, end_pos)
        BufferServer.delete_range(buf, start_pos, end_pos)
        %{state | register: text}

      {:yank, {start_pos, end_pos}} ->
        text = BufferServer.get_range(buf, start_pos, end_pos)
        Logger.debug("Yanked text object: #{byte_size(text)} bytes")
        %{state | register: text}
    end
  end

  @spec compute_text_object_range(GapBuffer.t(), TextObject.position(), atom(), term()) ::
          TextObject.range()
  defp compute_text_object_range(buf, pos, :inner, :word), do: TextObject.inner_word(buf, pos)
  defp compute_text_object_range(buf, pos, :around, :word), do: TextObject.a_word(buf, pos)

  defp compute_text_object_range(buf, pos, :inner, {:quote, q}),
    do: TextObject.inner_quotes(buf, pos, q)

  defp compute_text_object_range(buf, pos, :around, {:quote, q}),
    do: TextObject.a_quotes(buf, pos, q)

  defp compute_text_object_range(buf, pos, :inner, {:paren, open, close}),
    do: TextObject.inner_parens(buf, pos, open, close)

  defp compute_text_object_range(buf, pos, :around, {:paren, open, close}),
    do: TextObject.a_parens(buf, pos, open, close)

  defp compute_text_object_range(_buf, _pos, _modifier, _spec), do: nil

  # Move the cursor by `delta` lines (positive = down, negative = up),
  # clamping to buffer bounds. Column is preserved or clamped to the new line's length.
  @spec page_move(pid(), Viewport.t(), integer()) :: :ok
  defp page_move(buf, _vp, delta) do
    {line, col} = BufferServer.cursor(buf)
    total_lines = BufferServer.line_count(buf)
    target_line = line + delta
    target_line = max(0, min(target_line, total_lines - 1))

    # Clamp column to the new line's length
    target_col =
      case BufferServer.get_lines(buf, target_line, 1) do
        [text] -> min(col, max(0, String.length(text) - 1))
        [] -> 0
      end

    BufferServer.move_to(buf, {target_line, target_col})
  end

  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  defp start_buffer(file_path) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {BufferServer, file_path: file_path}
    )
  end

  # ── Buffer management helpers ────────────────────────────────────────────

  # Adds a new buffer to the list and makes it active.
  @spec add_buffer(state(), pid()) :: state()
  defp add_buffer(state, pid) do
    buffers = state.buffers ++ [pid]
    idx = length(buffers) - 1
    %{state | buffers: buffers, active_buffer: idx, buffer: pid}
  end

  # Switches to the buffer at the given index.
  @spec switch_to_buffer(state(), non_neg_integer()) :: state()
  defp switch_to_buffer(%{buffers: buffers} = state, idx) when length(buffers) > 0 do
    idx = rem(idx, length(buffers))
    idx = if idx < 0, do: idx + length(buffers), else: idx
    pid = Enum.at(buffers, idx)
    %{state | active_buffer: idx, buffer: pid}
  end

  defp switch_to_buffer(state, _idx), do: state

  # Switches to the next buffer (wraps around).
  @spec next_buffer(state()) :: state()
  defp next_buffer(%{buffers: buffers, active_buffer: idx} = state) when length(buffers) > 1 do
    switch_to_buffer(state, rem(idx + 1, length(buffers)))
  end

  defp next_buffer(state), do: state

  # Switches to the previous buffer (wraps around).
  @spec prev_buffer(state()) :: state()
  defp prev_buffer(%{buffers: buffers, active_buffer: idx} = state) when length(buffers) > 1 do
    new_idx = if idx == 0, do: length(buffers) - 1, else: idx - 1
    switch_to_buffer(state, new_idx)
  end

  defp prev_buffer(state), do: state

  # Removes the current buffer and switches to the next one.
  # If it's the last buffer, leaves the editor with no buffer.
  @spec remove_current_buffer(state()) :: state()
  defp remove_current_buffer(%{buffers: buffers, active_buffer: idx} = state)
       when length(buffers) > 0 do
    buf = Enum.at(buffers, idx)
    # Stop the buffer process
    if buf && Process.alive?(buf), do: GenServer.stop(buf, :normal)

    new_buffers = List.delete_at(buffers, idx)

    case new_buffers do
      [] ->
        %{state | buffers: [], active_buffer: 0, buffer: nil}

      _ ->
        new_idx = min(idx, length(new_buffers) - 1)
        new_active = Enum.at(new_buffers, new_idx)
        %{state | buffers: new_buffers, active_buffer: new_idx, buffer: new_active}
    end
  end

  defp remove_current_buffer(state), do: state

  # Finds a buffer by file path, returns its index or nil.
  @spec find_buffer_by_path(state(), String.t()) :: non_neg_integer() | nil
  defp find_buffer_by_path(%{buffers: buffers}, file_path) do
    Enum.find_index(buffers, fn buf ->
      Process.alive?(buf) && BufferServer.file_path(buf) == file_path
    end)
  end

  # ── Picker helpers ────────────────────────────────────────────────────────

  @escape 27
  @enter 13
  @arrow_down 57_424
  @arrow_up 57_416

  @spec open_buffer_picker(state()) :: state()
  defp open_buffer_picker(%{buffers: []} = state), do: state

  defp open_buffer_picker(%{buffers: buffers, active_buffer: active_idx} = state) do
    items =
      buffers
      |> Enum.with_index()
      |> Enum.map(fn {buf, idx} ->
        name =
          case BufferServer.file_path(buf) do
            nil -> "[scratch]"
            path -> Path.basename(path)
          end

        desc =
          case BufferServer.file_path(buf) do
            nil -> ""
            path -> path
          end

        dirty = if BufferServer.dirty?(buf), do: " [+]", else: ""

        {idx, name <> dirty, desc}
      end)

    picker = Picker.new(items, title: "Switch buffer", max_visible: 10)

    # Clear whichkey state if active
    new_state =
      if state.whichkey_timer do
        WhichKey.cancel_timeout(state.whichkey_timer)
        %{state | whichkey_node: nil, whichkey_timer: nil, show_whichkey: false}
      else
        state
      end

    %{new_state | picker: picker, picker_prev_buffer: active_idx}
  end

  @spec handle_picker_key(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp handle_picker_key(%{picker: _picker} = state, @escape, _mods) do
    # Cancel: restore previous buffer
    case state.picker_prev_buffer do
      nil -> %{state | picker: nil, picker_prev_buffer: nil}
      idx -> %{switch_to_buffer(state, idx) | picker: nil, picker_prev_buffer: nil}
    end
  end

  defp handle_picker_key(%{picker: picker} = state, @enter, _mods) do
    # Select: switch to the selected buffer
    case Picker.selected_id(picker) do
      nil ->
        %{state | picker: nil, picker_prev_buffer: nil}

      idx ->
        %{switch_to_buffer(state, idx) | picker: nil, picker_prev_buffer: nil}
    end
  end

  # C-j or arrow down → move selection down
  defp handle_picker_key(%{picker: picker} = state, cp, mods)
       when (cp == ?j and band(mods, @ctrl) != 0) or cp == @arrow_down do
    new_picker = Picker.move_down(picker)
    state = %{state | picker: new_picker}
    maybe_preview_picker_selection(state)
  end

  # C-k or arrow up → move selection up
  defp handle_picker_key(%{picker: picker} = state, cp, mods)
       when (cp == ?k and band(mods, @ctrl) != 0) or cp == @arrow_up do
    new_picker = Picker.move_up(picker)
    state = %{state | picker: new_picker}
    maybe_preview_picker_selection(state)
  end

  # Backspace
  defp handle_picker_key(%{picker: picker} = state, cp, _mods) when cp in [8, 127] do
    new_picker = Picker.backspace(picker)
    state = %{state | picker: new_picker}
    maybe_preview_picker_selection(state)
  end

  # Printable characters → filter
  defp handle_picker_key(%{picker: picker} = state, codepoint, 0)
       when codepoint >= 32 and codepoint <= 0x10FFFF do
    char =
      try do
        <<codepoint::utf8>>
      rescue
        ArgumentError -> nil
      end

    case char do
      nil ->
        state

      c ->
        new_picker = Picker.type_char(picker, c)
        state = %{state | picker: new_picker}
        maybe_preview_picker_selection(state)
    end
  end

  # Ignore all other keys
  defp handle_picker_key(state, _cp, _mods), do: state

  # Preview: temporarily switch to the selected buffer's content
  @spec maybe_preview_picker_selection(state()) :: state()
  defp maybe_preview_picker_selection(%{picker: picker} = state) do
    case Picker.selected_id(picker) do
      nil -> state
      idx -> switch_to_buffer(state, idx)
    end
  end

  # ── Visual selection helpers ──────────────────────────────────────────────

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

  @spec visual_selection_bounds(state(), Minga.Buffer.GapBuffer.position()) ::
          visual_selection()
  defp visual_selection_bounds(%{mode: :visual, mode_state: %VisualState{} = ms}, cursor) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type

    case visual_type do
      :char ->
        {start_pos, end_pos} = sort_positions(anchor, cursor)
        {:char, start_pos, end_pos}

      :line ->
        {anchor_line, _} = anchor
        {cursor_line, _} = cursor
        {:line, min(anchor_line, cursor_line), max(anchor_line, cursor_line)}
    end
  end

  defp visual_selection_bounds(_state, _cursor), do: nil

  @spec sort_positions(
          Minga.Buffer.GapBuffer.position(),
          Minga.Buffer.GapBuffer.position()
        ) :: {Minga.Buffer.GapBuffer.position(), Minga.Buffer.GapBuffer.position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  # Renders a single buffer line, applying visual selection highlights.
  @spec render_line(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.Editor.Viewport.t(),
          visual_selection()
        ) :: [binary()]
  defp render_line(line_text, screen_row, buf_line, viewport, visual_selection) do
    graphemes = String.graphemes(line_text)
    line_len = length(graphemes)

    # Compute visible graphemes accounting for horizontal scroll
    visible_graphemes =
      graphemes
      |> Enum.drop(viewport.left)
      |> Enum.take(viewport.cols)

    case selection_cols_for_line(buf_line, line_len, visual_selection) do
      nil ->
        # No selection on this line
        [Protocol.encode_draw(screen_row, 0, Enum.join(visible_graphemes))]

      :full ->
        # Entire line is selected (linewise or full-line char selection)
        [Protocol.encode_draw(screen_row, 0, Enum.join(visible_graphemes), reverse: true)]

      {sel_start, sel_end} ->
        # Partial line selection — split into three segments
        before_sel = Enum.take(visible_graphemes, max(0, sel_start - viewport.left))

        sel_graphemes =
          visible_graphemes
          |> Enum.drop(max(0, sel_start - viewport.left))
          |> Enum.take(sel_end - max(sel_start, viewport.left) + 1)

        after_sel =
          Enum.drop(
            visible_graphemes,
            max(0, sel_start - viewport.left) + length(sel_graphemes)
          )

        before_text = Enum.join(before_sel)
        sel_text = Enum.join(sel_graphemes)
        after_text = Enum.join(after_sel)

        [
          Protocol.encode_draw(screen_row, 0, before_text),
          Protocol.encode_draw(
            screen_row,
            length(before_sel),
            sel_text,
            reverse: true
          ),
          Protocol.encode_draw(
            screen_row,
            length(before_sel) + length(sel_graphemes),
            after_text
          )
        ]
    end
  end

  @typedoc "Column range of a selection on a single line."
  @type line_selection :: nil | :full | {non_neg_integer(), non_neg_integer()}

  @spec selection_cols_for_line(
          non_neg_integer(),
          non_neg_integer(),
          visual_selection()
        ) :: line_selection()
  defp selection_cols_for_line(_buf_line, _line_len, nil), do: nil

  defp selection_cols_for_line(buf_line, _line_len, {:line, start_line, end_line}) do
    if buf_line >= start_line and buf_line <= end_line, do: :full, else: nil
  end

  defp selection_cols_for_line(
         buf_line,
         line_len,
         {:char, {start_line, start_col}, {end_line, end_col}}
       ) do
    cond do
      buf_line < start_line or buf_line > end_line ->
        nil

      start_line == end_line ->
        {start_col, end_col}

      buf_line == start_line ->
        {start_col, max(0, line_len - 1)}

      buf_line == end_line ->
        {0, end_col}

      true ->
        :full
    end
  end
end
