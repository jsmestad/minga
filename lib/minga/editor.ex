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

    state = %EditorState{
      buffer: buffer,
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
        new_state = %{state | buffer: pid}
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
    Logger.debug("Opening file: #{file_path}")
    state
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

  defp execute_command(%{buffer: buf, mode_state: %VisualState{} = ms} = state, :delete_visual_selection) do
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

  defp execute_command(%{buffer: buf, mode_state: %VisualState{} = ms} = state, :yank_visual_selection) do
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
    Logger.debug("buffer_list: not yet implemented")
    state
  end

  defp execute_command(state, :kill_buffer) do
    Logger.debug("kill_buffer: not yet implemented")
    state
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

    # Status line
    {cursor_line, cursor_col} = cursor
    file_name = BufferServer.file_path(state.buffer) || "[scratch]"
    dirty_marker = if BufferServer.dirty?(state.buffer), do: " [+]", else: ""
    line_count = BufferServer.line_count(state.buffer)
    mode_label = Mode.display(state.mode, state.mode_state)

    status_text =
      case state.mode do
        :command ->
          # In command mode the status line becomes the ex command line.
          mode_label

        _ ->
          " #{file_name}#{dirty_marker}  #{cursor_line + 1}:#{cursor_col + 1}  #{line_count}L  #{mode_label}"
      end

    status_row = viewport.rows - 1

    status_command =
      Protocol.encode_draw(
        status_row,
        0,
        String.pad_trailing(status_text, viewport.cols),
        fg: 0x000000,
        bg: 0xCCCCCC,
        bold: true
      )

    cursor_row = cursor_line - viewport.top
    cursor_col_screen = cursor_col - viewport.left
    cursor_command = Protocol.encode_cursor(cursor_row, cursor_col_screen)

    whichkey_commands = maybe_render_whichkey(state, viewport)

    all_commands =
      clear ++
        line_commands ++
        tilde_commands ++
        [status_command] ++
        whichkey_commands ++
        [cursor_command, Protocol.encode_batch_end()]

    PortManager.send_commands(state.port_manager, all_commands)
    :ok
  end

  @spec maybe_render_whichkey(state(), Viewport.t()) :: [binary()]
  defp maybe_render_whichkey(%{show_whichkey: true, whichkey_node: node}, viewport)
       when not is_nil(node) do
    bindings = WhichKey.bindings_from_node(node)
    lines = WhichKey.render_popup(bindings)

    popup_row = max(0, viewport.rows - 2 - length(lines))

    ([Protocol.encode_draw(popup_row, 0, String.duplicate("─", viewport.cols), fg: 0x888888)] ++
       lines)
    |> Enum.with_index(popup_row + 1)
    |> Enum.map(fn {line_text, row} ->
      padded = String.pad_trailing(line_text, viewport.cols)
      Protocol.encode_draw(row, 0, padded, fg: 0xEEEEEE, bg: 0x333333)
    end)
  end

  defp maybe_render_whichkey(_state, _viewport), do: []

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

  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  defp start_buffer(file_path) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {BufferServer, file_path: file_path}
    )
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
