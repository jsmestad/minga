defmodule Minga.Test.HeadlessPort do
  @moduledoc """
  Virtual port manager that captures render commands into an in-memory
  screen grid. Drop-in replacement for `MingaEditor.Frontend.Manager` in tests.

  Decodes semantic GUI render commands from the editor's render pipeline into a queryable 2D cell grid. The `commit_frame` opcode (which closes each frame transaction, #2219) marks a complete frame and notifies waiters, providing a natural synchronization point for test assertions.

  ## Usage

      {:ok, port} = HeadlessPort.start_link(width: 80, height: 24)
      # ... editor sends render commands ...
      screen = HeadlessPort.get_screen_text(port)
      assert Enum.at(screen, 0) =~ "hello"
  """

  use GenServer

  @behaviour MingaEditor.Frontend.Adapter

  import Bitwise

  alias Minga.Core.Unicode
  alias Minga.Protocol.Opcodes
  alias Minga.Test.GUIWindowDecoder
  alias MingaEditor.Frontend.Protocol

  @op_begin_frame Opcodes.begin_frame()
  @op_commit_frame Opcodes.commit_frame()
  @op_set_title Opcodes.set_title()
  @op_set_window_bg Opcodes.set_window_bg()
  @op_set_font Opcodes.set_font()
  @op_set_font_fallback Opcodes.set_font_fallback()
  @op_register_font Opcodes.register_font()
  @op_gui_window_content Opcodes.gui_window_content()
  @op_gui_window_overlay_delta Opcodes.gui_window_overlay_delta()
  @op_gui_window_viewport_delta Opcodes.gui_window_viewport_delta()
  @op_gui_window_rows_delta Opcodes.gui_window_rows_delta()
  @op_gui_gutter Opcodes.gui_gutter()
  @op_gui_tab_bar Opcodes.gui_tab_bar()
  @op_gui_status_bar Opcodes.gui_status_bar()
  @op_gui_minibuffer Opcodes.gui_minibuffer()
  @op_gui_file_tree Opcodes.gui_file_tree()
  @op_gui_file_tree_selection Opcodes.gui_file_tree_selection()
  @op_gui_agent_chat Opcodes.gui_agent_chat()

  @typedoc "A single cell in the screen grid."
  @type cell :: %{
          char: String.t(),
          fg: non_neg_integer(),
          bg: non_neg_integer(),
          attrs: [atom()]
        }

  @typedoc "The screen grid: list of rows, each a list of cells."
  @type grid :: [[cell()]]

  @typedoc "Screen snapshot with grid and cursor position."
  @type screen :: %{
          grid: grid(),
          cursor: {non_neg_integer(), non_neg_integer()},
          cursor_shape: Protocol.cursor_shape(),
          width: pos_integer(),
          height: pos_integer()
        }

  @type start_opt ::
          {:name, GenServer.name()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}
          | {:capabilities, MingaEditor.Frontend.Capabilities.t()}

  defmodule State do
    @moduledoc false
    @enforce_keys [:width, :height]
    defstruct [
      :width,
      :height,
      grid: [],
      cursor: {0, 0},
      cursor_shape: :block,
      capabilities: MingaEditor.Frontend.Capabilities.default(),
      windows: %{},
      row_cache: %{},
      gutters: %{},
      tab_bar: nil,
      status_bar: nil,
      minibuffer: nil,
      file_tree: nil,
      agent_chat: nil,
      subscribers: [],
      waiters: [],
      frame_count: 0,
      transaction: nil,
      last_frame_seq: 0,
      recovery_generation: 0,
      production_outcome: :unknown
    ]

    @type t :: %__MODULE__{
            width: pos_integer(),
            height: pos_integer(),
            grid: [[map()]],
            cursor: {non_neg_integer(), non_neg_integer()},
            cursor_shape: MingaEditor.Frontend.Protocol.cursor_shape(),
            capabilities: MingaEditor.Frontend.Capabilities.t(),
            windows: map(),
            row_cache: map(),
            gutters: map(),
            tab_bar: map() | nil,
            status_bar: map() | nil,
            minibuffer: map() | nil,
            file_tree: map() | nil,
            agent_chat: map() | nil,
            subscribers: [pid()],
            waiters: [{pid(), reference()}],
            frame_count: non_neg_integer(),
            transaction: map() | nil,
            last_frame_seq: non_neg_integer(),
            recovery_generation: non_neg_integer(),
            production_outcome:
              :unknown | :accepted | :recovery_required | :stale_discarded | :rejected
          }
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the headless port."
  @impl MingaEditor.Frontend.Adapter
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # ── Frontend behaviour ────────────────────────────────────────────────────────

  @doc "Sends encoded render commands to the headless screen grid."
  @impl MingaEditor.Frontend.Adapter
  @spec send_commands(GenServer.server(), [binary()]) ::
          MingaEditor.Frontend.Adapter.admission()
  def send_commands(server, commands) when is_list(commands) do
    GenServer.cast(server, {:send_commands, commands})
    :accepted
  end

  @doc "Submits commands through the production begin/commit transaction gate."
  @spec send_transaction(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [binary()]
        ) :: MingaEditor.Frontend.Adapter.admission()
  def send_transaction(server, seq, base, generation, commands) do
    send_commands(
      server,
      [Protocol.encode_begin_frame(seq, base, generation) | commands] ++
        [Protocol.encode_commit_frame(seq, 0)]
    )
  end

  @doc "Returns observed decoder/apply transaction state for production-gate tests."
  @spec production_state(GenServer.server()) :: map()
  def production_state(server), do: GenServer.call(server, :production_state)

  @doc "Subscribes the calling process to receive input events."
  @impl MingaEditor.Frontend.Adapter
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Returns the screen dimensions as `{width, height}`."
  @impl MingaEditor.Frontend.Adapter
  @spec terminal_size(GenServer.server()) :: {pos_integer(), pos_integer()} | nil
  def terminal_size(server) do
    GenServer.call(server, :terminal_size)
  end

  @doc "Returns whether the headless port is ready (always true)."
  @impl MingaEditor.Frontend.Adapter
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server) do
    GenServer.call(server, :ready?)
  end

  @doc "Returns default headless capabilities."
  @impl MingaEditor.Frontend.Adapter
  @spec capabilities(GenServer.server()) :: MingaEditor.Frontend.Capabilities.t()
  def capabilities(server) do
    GenServer.call(server, :capabilities)
  end

  # ── Screen query API ────────────────────────────────────────────────────────

  @doc "Returns the screen as a list of strings (one per row)."
  @spec get_screen_text(GenServer.server()) :: [String.t()]
  def get_screen_text(server) do
    GenServer.call(server, :get_screen_text)
  end

  @doc "Returns the full screen snapshot."
  @spec get_screen(GenServer.server()) :: screen()
  def get_screen(server) do
    GenServer.call(server, :get_screen)
  end

  @doc "Returns just the text of a specific row."
  @spec get_row_text(GenServer.server(), non_neg_integer()) :: String.t()
  def get_row_text(server, row) do
    GenServer.call(server, {:get_row_text, row})
  end

  @doc "Returns the cursor position from the last render."
  @spec get_cursor(GenServer.server()) :: {non_neg_integer(), non_neg_integer()}
  def get_cursor(server) do
    GenServer.call(server, :get_cursor)
  end

  @doc "Returns the current cursor shape."
  @spec get_cursor_shape(GenServer.server()) :: Protocol.cursor_shape()
  def get_cursor_shape(server) do
    GenServer.call(server, :get_cursor_shape)
  end

  @doc "Returns the cell at a given row and col."
  @spec get_cell(GenServer.server(), non_neg_integer(), non_neg_integer()) :: cell()
  def get_cell(server, row, col) do
    GenServer.call(server, {:get_cell, row, col})
  end

  @doc "Resizes the headless port grid to new dimensions."
  @spec resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def resize(server, width, height) do
    GenServer.call(server, {:resize, width, height})
  end

  @doc "Returns the total number of completed frames (commit_frame count)."
  @spec frame_count(GenServer.server()) :: non_neg_integer()
  def frame_count(server) do
    GenServer.call(server, :frame_count)
  end

  @doc """
  Returns the number of screen rows this port stacks above the editor surface
  (the tab-bar row). A real frontend subtracts this from terminal mouse
  coordinates before forwarding them to the BEAM, which addresses the editor in
  its own (offset-free) coordinate space.
  """
  @spec editor_row_offset(GenServer.server()) :: non_neg_integer()
  def editor_row_offset(server) do
    GenServer.call(server, :editor_row_offset)
  end

  @doc """
  Blocks until a new frame is rendered (commit_frame received).
  Returns `:ok` or `{:error, :timeout}`.
  """
  @spec await_frame(GenServer.server(), timeout()) :: :ok | {:error, :timeout}
  def await_frame(server, timeout \\ 1000) do
    ref = make_ref()
    :ok = GenServer.call(server, {:wait_for_frame, self(), ref})

    receive do
      {:frame_ready, ^ref, _snapshot} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Registers a frame waiter synchronously, returning a ref.
  Call this BEFORE triggering the action that causes a render,
  then use `collect_frame/2` to wait for the frame.
  """
  @spec prepare_await(GenServer.server()) :: reference()
  def prepare_await(server) do
    ref = make_ref()
    :ok = GenServer.call(server, {:wait_for_frame, self(), ref})
    ref
  end

  @doc """
  Waits for a frame using a ref from `prepare_await/1`.

  Returns `{:ok, snapshot}` where snapshot is the frozen screen state at
  the moment `commit_frame` was processed. This is race-free: no subsequent
  render can overwrite the captured data because it lives in the calling
  process's mailbox, not in the HeadlessPort's mutable grid.
  """
  @spec collect_frame(reference(), timeout()) :: {:ok, screen()} | {:error, :timeout}
  def collect_frame(ref, timeout \\ 5_000) do
    receive do
      {:frame_ready, ^ref, snapshot} -> {:ok, snapshot}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc "Resets the screen to blank state."
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)

    state = %State{
      width: width,
      height: height,
      grid: blank_grid(width, height),
      capabilities: Keyword.get(opts, :capabilities, MingaEditor.Frontend.Capabilities.default())
    }

    {:ok, state}
  end

  # ── PortManager-compatible interface ──

  # subscribe — called by Editor on init
  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    subscribers = [pid | state.subscribers] |> Enum.uniq()
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:terminal_size, _from, state) do
    {:reply, {state.width, state.height}, state}
  end

  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, true, state}
  end

  # ── Screen query interface ──

  def handle_call(:get_screen_text, _from, state) do
    text =
      Enum.map(state.grid, fn row ->
        row
        |> Enum.map_join(& &1.char)
        |> String.trim_trailing()
      end)

    {:reply, text, state}
  end

  def handle_call(:get_screen, _from, state) do
    screen = %{
      grid: state.grid,
      cursor: state.cursor,
      cursor_shape: state.cursor_shape,
      width: state.width,
      height: state.height
    }

    {:reply, screen, state}
  end

  def handle_call({:get_row_text, row}, _from, state) do
    text =
      state.grid
      |> Enum.at(row, [])
      |> Enum.map_join(& &1.char)
      |> String.trim_trailing()

    {:reply, text, state}
  end

  def handle_call(:get_cursor, _from, state) do
    {:reply, state.cursor, state}
  end

  def handle_call(:get_cursor_shape, _from, state) do
    {:reply, state.cursor_shape, state}
  end

  def handle_call({:get_cell, row, col}, _from, state) do
    cell =
      state.grid
      |> Enum.at(row, [])
      |> Enum.at(col, %{char: " ", fg: 0xFFFFFF, bg: 0x000000, attrs: []})

    {:reply, cell, state}
  end

  def handle_call(:production_state, _from, state) do
    windows =
      Map.new(state.windows, fn {id, window} ->
        {id,
         %{row_count: length(window.rows), rows: window.rows, content_epoch: window.content_epoch}}
      end)

    {:reply,
     %{
       outcome: state.production_outcome,
       last_frame_seq: state.last_frame_seq,
       recovery_generation: state.recovery_generation,
       windows: windows
     }, state}
  end

  def handle_call(:frame_count, _from, state) do
    {:reply, state.frame_count, state}
  end

  def handle_call(:editor_row_offset, _from, state) do
    {:reply, top_chrome_offset(state), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok,
     %{
       state
       | grid: blank_grid(state.width, state.height),
         cursor: {0, 0},
         windows: %{},
         row_cache: %{},
         gutters: %{},
         tab_bar: nil,
         status_bar: nil,
         minibuffer: nil,
         file_tree: nil,
         agent_chat: nil,
         frame_count: 0
     }}
  end

  def handle_call({:resize, width, height}, _from, state) do
    {:reply, :ok, %{state | width: width, height: height, grid: blank_grid(width, height)}}
  end

  def handle_call({:wait_for_frame, pid, ref}, _from, state) do
    {:reply, :ok, %{state | waiters: [{pid, ref} | state.waiters]}}
  end

  def handle_call({:send_commands, commands}, _from, state) do
    {:reply, :accepted, apply_commands(state, commands)}
  end

  def handle_call({:send_render_commands, commands, sent_at}, _from, state) do
    Minga.Telemetry.hop_latency(:send_commands, sent_at)
    {:reply, :accepted, apply_commands(state, commands)}
  end

  # ── send_commands — the core render capture ──

  @impl true
  def handle_cast({:hop_mark, hop, sent_at}, state) do
    Minga.Telemetry.hop_latency(hop, sent_at)
    {:noreply, state}
  end

  def handle_cast({:send_commands, commands}, state),
    do: {:noreply, apply_commands(state, commands)}

  @spec apply_commands(State.t(), [binary()]) :: State.t()
  defp apply_commands(state, commands), do: Enum.reduce(commands, state, &apply_command/2)

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, &(&1 == pid))
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Command application ────────────────────────────────────────────────────

  @spec apply_command(binary(), State.t()) :: State.t()

  # Production transaction gate. Commands are decoded/applied only at commit,
  # against an immutable state value, so rejection cannot partially publish.
  defp apply_command(<<@op_begin_frame, frame_seq::32, base::32, generation::32>>, state) do
    %{state | transaction: %{seq: frame_seq, base: base, generation: generation, commands: []}}
  end

  defp apply_command(
         <<@op_commit_frame, frame_seq::32, input_seq::32>>,
         %{transaction: tx} = state
       )
       when not is_nil(tx) do
    commit_transaction(state, tx, frame_seq, input_seq)
  end

  defp apply_command(<<@op_commit_frame, _frame_seq::32, input_seq::32>>, state),
    do: apply_commit_frame(state, input_seq)

  defp apply_command(command, %{transaction: tx} = state) when not is_nil(tx) do
    %{state | transaction: %{tx | commands: tx.commands ++ [command]}}
  end

  defp apply_command(<<@op_gui_window_content, _rest::binary>> = binary, state) do
    window = GUIWindowDecoder.decode(binary)
    row_cache = remember_rows(state.row_cache, window.window_id, window.rows)
    %{state | windows: Map.put(state.windows, window.window_id, window), row_cache: row_cache}
  end

  defp apply_command(<<opcode, _rest::binary>> = binary, state)
       when opcode in [@op_gui_window_viewport_delta, @op_gui_window_rows_delta] do
    <<_opcode, _count, _header_id, _header_len::32, window_id::16, _rest::binary>> = binary
    current = Map.get(state.windows, window_id, %{})

    {window, row_cache} =
      decode_window_rows_delta(binary, state.row_cache, Map.get(current, :rows, []))

    %{
      state
      | windows: Map.put(state.windows, window.window_id, Map.merge(current, window)),
        row_cache: row_cache
    }
  end

  defp apply_command(<<@op_gui_window_overlay_delta, rest::binary>>, state) do
    <<window_id::16, content_epoch::32, flags::8, cursor_row::16, cursor_col::16, cursor_shape::8,
      tail::binary>> = rest

    current =
      Map.get(state.windows, window_id, %{
        window_id: window_id,
        rows: [],
        geometry: nil,
        scroll_left: 0
      })

    window =
      current
      |> Map.put(:content_epoch, content_epoch)
      |> Map.put(:cursor_visible, (flags &&& 1) == 1)
      |> Map.put(:cursor_row, cursor_row)
      |> Map.put(:cursor_col, cursor_col)
      |> Map.put(:cursor_shape, decode_cursor_shape(cursor_shape))
      |> maybe_put_overlay_cursorline(flags, tail)

    %{state | windows: Map.put(state.windows, window_id, window)}
  end

  defp apply_command(<<@op_gui_gutter, _rest::binary>> = binary, state) do
    gutter = decode_gutter(binary)
    %{state | gutters: Map.put(state.gutters, gutter.window_id, gutter)}
  end

  defp apply_command(<<@op_gui_tab_bar, rest::binary>>, state),
    do: %{state | tab_bar: decode_tab_bar(rest)}

  defp apply_command(<<@op_gui_status_bar, rest::binary>>, state),
    do: %{state | status_bar: decode_status_bar(rest)}

  defp apply_command(<<@op_gui_minibuffer, rest::binary>>, state),
    do: %{state | minibuffer: decode_minibuffer(rest)}

  defp apply_command(<<@op_gui_agent_chat, rest::binary>>, state),
    do: %{state | agent_chat: decode_agent_chat(rest)}

  defp apply_command(<<@op_gui_file_tree, _len::32, payload::binary>>, state),
    do: %{state | file_tree: decode_file_tree(payload)}

  defp apply_command(<<@op_gui_file_tree_selection, _len::16, payload::binary>>, state),
    do: %{state | file_tree: apply_file_tree_selection(state.file_tree, payload)}

  defp apply_command(<<opcode, _rest::binary>>, state)
       when opcode in [
              @op_set_title,
              @op_set_window_bg,
              @op_set_font,
              @op_set_font_fallback,
              @op_register_font
            ],
       do: state

  defp apply_command(_cmd_binary, state), do: state

  @spec commit_transaction(State.t(), map(), non_neg_integer(), non_neg_integer()) :: State.t()
  defp commit_transaction(state, tx, frame_seq, input_seq) do
    valid_base? = tx.base == 0 or tx.base == state.last_frame_seq

    case {frame_seq == tx.seq and valid_base?, tx.generation < state.recovery_generation} do
      {_, true} -> %{state | transaction: nil, production_outcome: :stale_discarded}
      {false, _} -> %{state | transaction: nil, production_outcome: :rejected}
      {true, false} -> apply_staged_transaction(state, tx, input_seq)
    end
  end

  @spec apply_staged_transaction(State.t(), map(), non_neg_integer()) :: State.t()
  defp apply_staged_transaction(state, tx, input_seq) do
    base = %{state | transaction: nil}

    try do
      next = Enum.reduce(tx.commands, base, &apply_staged_command/2)
      next = apply_commit_frame(next, input_seq)

      %{
        next
        | last_frame_seq: tx.seq,
          recovery_generation: tx.generation,
          production_outcome: :accepted
      }
    rescue
      KeyError -> %{base | production_outcome: :recovery_required}
      MatchError -> %{base | production_outcome: :rejected}
      ArgumentError -> %{base | production_outcome: :rejected}
    catch
      :throw, :stale_content_epoch -> %{base | production_outcome: :stale_discarded}
    end
  end

  @spec apply_staged_command(binary(), State.t()) :: State.t()
  defp apply_staged_command(<<opcode, _rest::binary>> = command, state)
       when opcode in [@op_gui_window_viewport_delta, @op_gui_window_rows_delta] do
    <<_opcode, _count, _header_id, _header_len::32, window_id::16, content_epoch::32,
      _rest::binary>> = command

    case state.windows do
      %{^window_id => %{content_epoch: ^content_epoch}} -> apply_command(command, state)
      _ -> throw(:stale_content_epoch)
    end
  end

  defp apply_staged_command(command, state), do: apply_command(command, state)

  @spec apply_commit_frame(State.t(), non_neg_integer()) :: State.t()
  defp apply_commit_frame(state, input_seq) do
    state = project_semantic_grid(state)

    snapshot = %{
      grid: state.grid,
      cursor: state.cursor,
      cursor_shape: state.cursor_shape,
      width: state.width,
      height: state.height,
      input_seq: input_seq
    }

    Enum.each(state.waiters, fn {pid, ref} ->
      send(pid, {:frame_ready, ref, snapshot})
    end)

    %{state | waiters: [], frame_count: state.frame_count + 1}
  end

  @spec project_semantic_grid(State.t()) :: State.t()
  defp project_semantic_grid(state) do
    state = %{state | grid: blank_grid(state.width, state.height)}
    state = draw_file_tree(state, state.file_tree)
    state = draw_windows(state)
    state = draw_tab_bar(state, state.tab_bar)
    state = draw_agent_chat(state, state.agent_chat)
    state = draw_status_bar(state, state.status_bar)
    draw_minibuffer(state, state.minibuffer)
  end

  @spec draw_text(State.t(), non_neg_integer(), non_neg_integer(), String.t()) :: State.t()
  defp draw_text(state, row, col, text),
    do: draw_text(state, row, col, 0xFFFFFF, 0x000000, [], text)

  @spec draw_text(
          State.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [atom()],
          String.t()
        ) :: State.t()
  defp draw_text(state, row, col, fg, bg, attrs, text) do
    if row >= state.height do
      state
    else
      grid_row = Enum.at(state.grid, row)

      new_row =
        text
        |> String.graphemes()
        |> Enum.with_index(col)
        |> Enum.filter(fn {_char, c} -> c < state.width end)
        |> Enum.reduce(grid_row, fn {char, c}, acc ->
          List.replace_at(acc, c, %{char: char, fg: fg, bg: bg, attrs: attrs})
        end)

      %{state | grid: List.replace_at(state.grid, row, new_row)}
    end
  end

  @spec draw_windows(State.t()) :: State.t()
  defp draw_windows(state) do
    offset = top_chrome_offset(state)

    state.windows
    |> Map.values()
    |> Enum.sort_by(fn window -> window_origin(window) end)
    |> Enum.reduce(state, fn window, acc ->
      acc = draw_window_gutter(acc, window, Map.get(acc.gutters, window.window_id), offset)
      draw_window_rows(acc, window, offset)
    end)
  end

  # The BEAM's semantic GUI layout reserves no editor rows for the tab bar or
  # status bar (`Layout.TUI` was deleted in #2235); the emitted window fills the
  # viewport minus the minibuffer row. Like the production Go TUI, this headless
  # port renders a one-row tab bar above the editor and a status bar +
  # minibuffer below it, then clips the taller emitted window to the rows that
  # remain (the Go `bodyHeight` clip). Window content shifts down by the tab-bar
  # height and is clamped to the content region; the file tree already starts at
  # the first editor row.
  @spec top_chrome_offset(State.t()) :: non_neg_integer()
  defp top_chrome_offset(%{tab_bar: nil}), do: 0
  defp top_chrome_offset(_state), do: 1

  # Rows reserved below the editor: the status bar (rows-2) and minibuffer (rows-1).
  @bottom_chrome_rows 2

  # Number of editor rows the port shows after reserving top and bottom chrome.
  @spec content_region_height(State.t(), non_neg_integer()) :: non_neg_integer()
  defp content_region_height(state, offset) do
    max(state.height - offset - @bottom_chrome_rows, 0)
  end

  @spec draw_window_rows(State.t(), map(), non_neg_integer()) :: State.t()
  defp draw_window_rows(state, %{rows: rows} = window, offset) do
    {row0, col0} = window_text_origin(window)
    row0 = row0 + offset
    region = content_region_height(state, offset)

    state =
      rows
      |> Enum.with_index()
      |> Enum.reduce(state, fn {row, display_row}, acc ->
        if display_row < region do
          draw_semantic_row(
            acc,
            row0 + display_row,
            col0,
            row,
            display_row,
            Map.get(window, :selection)
          )
        else
          acc
        end
      end)

    rows
    |> length()
    |> draw_window_tildes(state, window, row0, col0, region)
    |> put_window_cursor(window, offset)
  end

  defp draw_window_rows(state, _window, _offset), do: state

  @spec draw_window_tildes(
          non_neg_integer(),
          State.t(),
          map(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: State.t()
  defp draw_window_tildes(row_count, state, window, row0, col0, region) do
    # Fill empty editor rows with tildes, clamped to the content region so they
    # never bleed into the status bar or minibuffer.
    height = min(window_text_height(window), region)

    row_count..max(row_count, height - 1)
    |> Enum.reduce(state, fn display_row, acc ->
      if display_row < height do
        draw_text(acc, row0 + display_row, col0, "~")
      else
        acc
      end
    end)
  end

  @spec draw_window_gutter(State.t(), map(), map() | nil, non_neg_integer()) :: State.t()
  defp draw_window_gutter(state, _window, nil, _offset), do: state

  defp draw_window_gutter(state, _window, gutter, offset) do
    region = content_region_height(state, offset)

    gutter.entries
    |> Enum.with_index(gutter.content_row)
    |> Enum.reduce(state, fn {entry, display_row}, acc ->
      if display_row - gutter.content_row < region do
        draw_text(acc, display_row + offset, gutter.content_col, gutter_entry_text(gutter, entry))
      else
        acc
      end
    end)
  end

  @spec put_window_cursor(State.t(), map(), non_neg_integer()) :: State.t()
  defp put_window_cursor(state, window, offset) do
    # A window whose cursor is hidden (e.g. while a minibuffer input mode owns
    # the cursor) must not position the terminal cursor. Mirrors the Zig
    # `windowCursorPosition`, which returns null when `cursor_visible` is false.
    if Map.get(window, :cursor_visible, true) do
      {row0, col0} = window_text_origin(window)
      row0 = row0 + offset
      cursor_shape = Map.get(window, :cursor_shape, :block)

      %{
        state
        | cursor:
            {row0 + Map.get(window, :cursor_row, 0), col0 + Map.get(window, :cursor_col, 0)},
          cursor_shape: cursor_shape
      }
    else
      state
    end
  end

  @spec draw_tab_bar(State.t(), map() | nil) :: State.t()
  defp draw_tab_bar(state, nil), do: state

  defp draw_tab_bar(state, %{tabs: tabs}) do
    text =
      tabs
      |> Enum.map_join(" ", fn tab ->
        label = tab.label <> if(tab.dirty?, do: " [+]", else: "")
        if(tab.active?, do: "[" <> label <> "]", else: " " <> label <> " ")
      end)

    draw_text(state, 0, 0, text)
  end

  @spec draw_status_bar(State.t(), map() | nil) :: State.t()
  defp draw_status_bar(state, nil), do: state

  defp draw_status_bar(state, status_bar) do
    text =
      [
        status_bar.mode,
        status_bar.filename,
        status_bar.branch,
        status_bar.cursor,
        status_bar.message
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    # The modeline always renders on the second-from-bottom row; the bottom row
    # is reserved for the message bar / minibuffer. Matches the Zig
    # `renderStatusBar` placement and the BEAM `Layout.TUI` (status bar at
    # rows-2, minibuffer at rows-1).
    row = if state.height > 1, do: state.height - 2, else: 0

    draw_text(state, row, 0, text)
  end

  @spec draw_minibuffer(State.t(), map() | nil) :: State.t()
  defp draw_minibuffer(state, nil), do: state
  defp draw_minibuffer(state, %{visible?: false}), do: state

  defp draw_minibuffer(state, minibuffer) do
    row = minibuffer_row(state)

    state
    |> draw_text(row, 0, minibuffer.prompt <> minibuffer.input)
    |> put_minibuffer_cursor(minibuffer, row)
  end

  # The minibuffer owns the bottom row (matches the Zig `renderMinibuffer` and
  # the BEAM TUI layout). The status bar, when present, sits one row above it.
  @spec minibuffer_row(State.t()) :: non_neg_integer()
  defp minibuffer_row(state), do: max(state.height - 1, 0)

  # Mirrors the Zig `minibufferCursorPosition`: an active minibuffer owns the
  # terminal cursor at prompt display width plus the display width of the input
  # prefix up to `cursor_pos`. 0xFFFF is the sentinel for "no cursor".
  @spec put_minibuffer_cursor(State.t(), map(), non_neg_integer()) :: State.t()
  defp put_minibuffer_cursor(state, minibuffer, row) do
    case Map.get(minibuffer, :cursor_pos, 0xFFFF) do
      0xFFFF ->
        state

      cursor_pos ->
        prompt = if minibuffer.prompt == "", do: "> ", else: minibuffer.prompt
        prompt_width = Unicode.display_width(prompt)

        input_prefix =
          minibuffer.input |> String.graphemes() |> Enum.take(cursor_pos) |> Enum.join()

        col = prompt_width + Unicode.display_width(input_prefix)

        if col < state.width do
          %{state | cursor: {row, col}, cursor_shape: :beam}
        else
          state
        end
    end
  end

  @spec draw_agent_chat(State.t(), map() | nil) :: State.t()
  defp draw_agent_chat(state, nil), do: state
  defp draw_agent_chat(state, %{visible?: false}), do: state

  defp draw_agent_chat(state, agent_chat) do
    border_row = max(state.height - 4, 0)
    content_row = min(border_row + 1, max(state.height - 1, 0))
    prompt = if agent_chat.prompt == "", do: "Type a message", else: agent_chat.prompt

    state
    |> draw_text(border_row, 0, "Prompt")
    |> draw_text(content_row, 0, prompt)
    |> then(fn acc ->
      %{acc | cursor: {content_row + agent_chat.prompt_cursor_line, agent_chat.prompt_cursor_col}}
    end)
  end

  @spec draw_file_tree(State.t(), map() | nil) :: State.t()
  defp draw_file_tree(state, nil), do: state
  defp draw_file_tree(state, %{visible?: false}), do: state

  defp draw_file_tree(state, %{rows: rows, width: width}) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {row, screen_row}, acc ->
      draw_text(acc, screen_row, 0, file_tree_row_text(row, width))
    end)
  end

  @spec draw_semantic_row(
          State.t(),
          non_neg_integer(),
          non_neg_integer(),
          map(),
          non_neg_integer(),
          map() | nil
        ) :: State.t()
  defp draw_semantic_row(
         state,
         screen_row,
         col0,
         %{row_type: :virtual_line, text: ""},
         _display_row,
         _selection
       ) do
    draw_text(state, screen_row, col0, "~")
  end

  defp draw_semantic_row(state, screen_row, col0, row, display_row, selection) do
    text = Map.get(row, :text, "")
    spans = Map.get(row, :spans, [])

    text
    |> String.graphemes()
    |> graphemes_with_display_cols()
    |> Enum.with_index(col0)
    |> Enum.filter(fn {{_char, _display_col}, col} -> col < state.width end)
    |> Enum.reduce(state, fn {{char, display_col}, col}, acc ->
      attrs =
        spans
        |> semantic_attrs_for_col(display_col)
        |> maybe_reverse_attr(selection, display_row, display_col)

      draw_text(acc, screen_row, col, 0xFFFFFF, 0x000000, attrs, char)
    end)
  end

  @spec window_origin(map()) :: {non_neg_integer(), non_neg_integer()}
  defp window_origin(%{geometry: %{total_rect: {row, col, _width, _height}}}), do: {row, col}
  defp window_origin(_window), do: {0, 0}

  @spec window_text_origin(map()) :: {non_neg_integer(), non_neg_integer()}
  defp window_text_origin(%{geometry: %{text_rect: {row, col, _width, _height}}}), do: {row, col}

  defp window_text_origin(%{geometry: %{content_rect: {row, col, _width, _height}}}),
    do: {row, col}

  defp window_text_origin(_window), do: {0, 0}

  @spec window_text_height(map()) :: non_neg_integer()
  defp window_text_height(%{geometry: %{text_rect: {_row, _col, _width, height}}}), do: height
  defp window_text_height(%{geometry: %{content_rect: {_row, _col, _width, height}}}), do: height
  defp window_text_height(window), do: length(Map.get(window, :rows, []))

  @spec remember_rows(map(), non_neg_integer(), [map()]) :: map()
  defp remember_rows(row_cache, window_id, rows) do
    window_cache = Map.get(row_cache, window_id, %{})
    rows_by_id = Map.new(rows, &{{&1.row_id, &1.content_hash}, &1})
    Map.put(row_cache, window_id, Map.merge(window_cache, rows_by_id))
  end

  @spec decode_window_rows_delta(binary(), map(), [map()]) :: {map(), map()}
  defp decode_window_rows_delta(
         <<_opcode::8, section_count::8, rest::binary>>,
         row_cache,
         base_rows
       ) do
    base = %{
      window_id: 0,
      rows: [],
      cursor_visible: true,
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      scroll_left: 0,
      content_epoch: 0,
      geometry: nil,
      base_rows: base_rows
    }

    {window, <<>>} = decode_delta_sections(rest, section_count, base, row_cache)
    window = Map.delete(window, :base_rows)
    {window, remember_rows(row_cache, window.window_id, window.rows)}
  end

  defp decode_delta_sections(rest, 0, result, _row_cache), do: {result, rest}

  defp decode_delta_sections(
         <<section_id::8, section_len::32, payload::binary-size(section_len), rest::binary>>,
         remaining,
         result,
         row_cache
       ) do
    result = decode_delta_section(section_id, payload, result, row_cache)
    decode_delta_sections(rest, remaining - 1, result, row_cache)
  end

  defp decode_delta_section(
         0x01,
         <<window_id::16, content_epoch::32, flags::8, cursor_row::16, cursor_col::16,
           cursor_shape::8, scroll_left::16>>,
         result,
         _row_cache
       ) do
    %{
      result
      | window_id: window_id,
        content_epoch: content_epoch,
        cursor_visible: (flags &&& 1) == 1,
        cursor_row: cursor_row,
        cursor_col: cursor_col,
        cursor_shape: decode_cursor_shape(cursor_shape),
        scroll_left: scroll_left
    }
  end

  defp decode_delta_section(
         0x02,
         <<row_count::32, rest::binary>>,
         %{window_id: window_id} = result,
         row_cache
       ) do
    {rows, <<>>} = decode_delta_rows(rest, row_count, Map.get(row_cache, window_id, %{}), [])
    %{result | rows: rows}
  end

  defp decode_delta_section(
         0x0B,
         <<base_count::32, result_count::32, splice_count::32, rest::binary>>,
         %{window_id: window_id, base_rows: base_rows} = result,
         row_cache
       ) do
    true = length(base_rows) == base_count
    window_cache = Map.get(row_cache, window_id, %{})
    {splices, <<>>} = decode_row_splices(rest, splice_count, window_cache, [])

    {rows, _offset} =
      Enum.reduce(splices, {base_rows, 0}, fn {start, delete_count, inserted}, {rows, offset} ->
        index = start + offset
        next_rows = Enum.take(rows, index) ++ inserted ++ Enum.drop(rows, index + delete_count)
        {next_rows, offset + length(inserted) - delete_count}
      end)

    true = length(rows) == result_count
    %{result | rows: rows}
  end

  defp decode_delta_section(0x08, payload, result, _row_cache),
    do: Map.put(result, :geometry, decode_geometry_payload(payload))

  defp decode_delta_section(0x09, <<row::16, r::8, g::8, b::8>>, result, _row_cache),
    do: Map.put(result, :cursorline, %{row: row, bg_rgb: r <<< 16 ||| g <<< 8 ||| b})

  defp decode_delta_section(_section_id, _payload, result, _row_cache), do: result

  defp decode_row_splices(rest, 0, _window_cache, acc), do: {Enum.reverse(acc), rest}

  defp decode_row_splices(
         <<start::32, delete_count::32, insert_count::32, rest::binary>>,
         remaining,
         window_cache,
         acc
       ) do
    {inserted, rest} = decode_delta_rows(rest, insert_count, window_cache, [])
    decode_row_splices(rest, remaining - 1, window_cache, [{start, delete_count, inserted} | acc])
  end

  defp decode_delta_rows(rest, 0, _window_cache, acc), do: {Enum.reverse(acc), rest}

  defp decode_delta_rows(
         <<0::8, row_id::64, content_hash::32, rest::binary>>,
         remaining,
         window_cache,
         acc
       ),
       do:
         decode_delta_rows(rest, remaining - 1, window_cache, [
           Map.fetch!(window_cache, {row_id, content_hash}) | acc
         ])

  defp decode_delta_rows(
         <<1::8, row_type::8, row_id::64, buf_line::32, content_hash::32, text_len::32,
           text::binary-size(text_len), span_count::16, rest::binary>>,
         remaining,
         window_cache,
         acc
       ) do
    {spans, rest} = decode_spans(rest, span_count, [])

    row = %{
      row_type: decode_row_type(row_type),
      row_id: row_id,
      buf_line: buf_line,
      content_hash: content_hash,
      text: text,
      spans: spans
    }

    decode_delta_rows(rest, remaining - 1, window_cache, [row | acc])
  end

  defp decode_spans(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_spans(
         <<start_col::16, end_col::16, fg::24, bg::24, attrs::8, _font_weight::8, _font_id::8,
           rest::binary>>,
         remaining,
         acc
       ),
       do:
         decode_spans(rest, remaining - 1, [
           %{start_col: start_col, end_col: end_col, fg: fg, bg: bg, attrs: attrs} | acc
         ])

  @spec decode_gutter(binary()) :: map()
  defp decode_gutter(<<@op_gui_gutter, section_count::8, rest::binary>>) do
    {gutter, <<>>} =
      decode_gutter_sections(rest, section_count, %{
        window_id: 0,
        content_row: 0,
        content_col: 0,
        content_height: 0,
        content_width: 0,
        cursor_line: 0,
        line_number_style: :none,
        line_number_width: 0,
        sign_col_width: 0,
        entries: []
      })

    gutter
  end

  defp decode_gutter_sections(rest, 0, result), do: {result, rest}

  defp decode_gutter_sections(
         <<section_id::8, section_len::16, payload::binary-size(section_len), rest::binary>>,
         remaining,
         result
       ),
       do:
         decode_gutter_sections(
           rest,
           remaining - 1,
           decode_gutter_section(section_id, payload, result)
         )

  defp decode_gutter_section(
         0x01,
         <<window_id::16, row::16, col::16, height::16, _active::8, width::16>>,
         result
       ),
       do: %{
         result
         | window_id: window_id,
           content_row: row,
           content_col: col,
           content_height: height,
           content_width: width
       }

  defp decode_gutter_section(
         0x02,
         <<cursor_line::32, style::8, line_width::8, sign_width::8>>,
         result
       ),
       do: %{
         result
         | cursor_line: cursor_line,
           line_number_style: decode_line_number_style(style),
           line_number_width: line_width,
           sign_col_width: sign_width
       }

  defp decode_gutter_section(0x03, <<count::16, rest::binary>>, result) do
    {entries, <<>>} = decode_gutter_entries(rest, count, [])
    %{result | entries: entries}
  end

  defp decode_gutter_section(_section_id, _payload, result), do: result

  defp decode_gutter_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_gutter_entries(
         <<buf_line::32, display_type::8, sign_type::8, fold_end_line::32, rest::binary>>,
         remaining,
         acc
       ) do
    {sign_text, rest} = decode_gutter_annotation(sign_type, rest)

    entry = %{
      buf_line: buf_line,
      display_type: decode_display_type(display_type),
      sign_type: decode_sign_type(sign_type),
      sign_text: sign_text,
      fold_end_line: fold_end_line
    }

    decode_gutter_entries(rest, remaining - 1, [entry | acc])
  end

  defp decode_gutter_annotation(
         8,
         <<_fg::24, text_len::8, text::binary-size(text_len), rest::binary>>
       ),
       do: {text, rest}

  defp decode_gutter_annotation(_sign_type, rest), do: {nil, rest}

  @spec gutter_entry_text(map(), map()) :: String.t()
  defp gutter_entry_text(gutter, entry) do
    sign = entry.sign_text || sign_text(entry.sign_type)

    line =
      line_number_text(
        gutter.line_number_style,
        gutter.cursor_line,
        entry.buf_line,
        entry.display_type
      )

    # Mirror the Zig renderer (semantic.zig `gutterText`): the line number is
    # right-aligned within `line_number_width - 1` columns and the last column of
    # the field is the separator space before the text. Total gutter width stays
    # `sign_col_width + line_number_width`, matching `GutterMetrics.total_width`.
    number_field = max(gutter.line_number_width - 1, 0)

    String.pad_trailing(sign, gutter.sign_col_width) <>
      (line |> String.pad_leading(number_field) |> String.pad_trailing(gutter.line_number_width))
  end

  defp line_number_text(:none, _cursor_line, _buf_line, _display_type), do: ""
  defp line_number_text(_style, _cursor_line, _buf_line, :blank), do: ""

  defp line_number_text(:absolute, _cursor_line, buf_line, _display_type),
    do: Integer.to_string(buf_line + 1)

  defp line_number_text(:relative, cursor_line, buf_line, _display_type),
    do: relative_line_number(cursor_line, buf_line)

  defp line_number_text(:hybrid, cursor_line, buf_line, _display_type),
    do:
      if(cursor_line == buf_line,
        do: Integer.to_string(buf_line + 1),
        else: relative_line_number(cursor_line, buf_line)
      )

  defp relative_line_number(cursor_line, buf_line),
    do: Integer.to_string(abs(cursor_line - buf_line))

  defp sign_text(:git_added), do: "+"
  defp sign_text(:git_modified), do: "~"
  defp sign_text(:git_deleted), do: "-"
  defp sign_text(:git_removed), do: "-"
  defp sign_text(:diag_error), do: "!"
  defp sign_text(:diag_warning), do: "!"
  defp sign_text(:diag_info), do: "i"
  defp sign_text(:diag_hint), do: "?"
  defp sign_text(_sign_type), do: ""

  @spec decode_tab_bar(binary()) :: map()
  defp decode_tab_bar(<<_active_index::8, count::8, rest::binary>>) do
    {tabs, <<>>} = decode_tab_entries(rest, count, [])
    %{tabs: tabs}
  end

  defp decode_tab_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_tab_entries(
         <<flags::8, id::32, workspace_id::16, icon_len::8, icon::binary-size(icon_len),
           label_len::16, label::binary-size(label_len), tint::32, rest::binary>>,
         remaining,
         acc
       ) do
    tab = %{
      id: id,
      workspace_id: workspace_id,
      icon: icon,
      label: label,
      tint: tint,
      active?: (flags &&& 1) == 1,
      dirty?: (flags &&& 2) == 2
    }

    decode_tab_entries(rest, remaining - 1, [tab | acc])
  end

  @spec decode_status_bar(binary()) :: map()
  defp decode_status_bar(<<section_count::8, rest::binary>>) do
    {status, <<>>} = decode_status_sections(rest, section_count, %{})
    status
  end

  defp decode_status_sections(rest, 0, result), do: {result, rest}

  defp decode_status_sections(
         <<section_id::8, section_len::16, payload::binary-size(section_len), rest::binary>>,
         remaining,
         result
       ),
       do:
         decode_status_sections(
           rest,
           remaining - 1,
           decode_status_section(section_id, payload, result)
         )

  defp decode_status_section(0x01, <<_kind::8, mode::8, _flags::8>>, result),
    do: Map.put(result, :mode, decode_mode(mode))

  defp decode_status_section(0x02, <<line::32, col::32, line_count::32>>, result),
    do: Map.put(result, :cursor, "#{line}:#{col}/#{line_count}")

  defp decode_status_section(
         0x05,
         <<branch_len::8, branch::binary-size(branch_len), _rest::binary>>,
         result
       ),
       do: Map.put(result, :branch, branch)

  defp decode_status_section(
         0x06,
         <<icon_len::8, _icon::binary-size(icon_len), _rgb::24, filename_len::16,
           filename::binary-size(filename_len), _filetype_len::8, _rest::binary>>,
         result
       ),
       do: Map.put(result, :filename, filename)

  defp decode_status_section(
         0x07,
         <<message_len::16, message::binary-size(message_len)>>,
         result
       ),
       do: Map.put(result, :message, message)

  defp decode_status_section(_section_id, _payload, result), do: result

  @spec decode_minibuffer(binary()) :: map()
  defp decode_minibuffer(<<0::8>>),
    do: %{visible?: false, prompt: "", input: "", cursor_pos: 0xFFFF}

  defp decode_minibuffer(
         <<1::8, _mode::8, cursor_pos::16, prompt_len::8, prompt::binary-size(prompt_len),
           input_len::16, input::binary-size(input_len), _rest::binary>>
       ),
       do: %{visible?: true, prompt: prompt, input: input, cursor_pos: cursor_pos}

  @spec decode_agent_chat(binary()) :: map()
  defp decode_agent_chat(<<0::8>>),
    do: %{visible?: false, prompt: "", prompt_cursor_line: 0, prompt_cursor_col: 0}

  defp decode_agent_chat(<<section_count::8, rest::binary>>) do
    {agent_chat, <<>>} =
      decode_agent_chat_sections(rest, section_count, %{
        visible?: true,
        prompt: "",
        prompt_cursor_line: 0,
        prompt_cursor_col: 0
      })

    agent_chat
  end

  defp decode_agent_chat_sections(rest, 0, result), do: {result, rest}

  defp decode_agent_chat_sections(
         <<section_id::8, section_len::16, payload::binary-size(section_len), rest::binary>>,
         remaining,
         result
       ),
       do:
         decode_agent_chat_sections(
           rest,
           remaining - 1,
           decode_agent_chat_section(section_id, payload, result)
         )

  defp decode_agent_chat_section(
         0x03,
         <<prompt_len::16, prompt::binary-size(prompt_len), _line_count::8,
           prompt_cursor_line::16, prompt_cursor_col::16, _vim_mode::8, _visible_rows::8>>,
         result
       ),
       do: %{
         result
         | prompt: prompt,
           prompt_cursor_line: prompt_cursor_line,
           prompt_cursor_col: prompt_cursor_col
       }

  defp decode_agent_chat_section(_section_id, _payload, result), do: result

  @spec decode_file_tree(binary()) :: map()
  defp decode_file_tree(
         <<2::8, flags::8, _status::8, selected_len::16, selected::binary-size(selected_len),
           root_len::16, root::binary-size(root_len), width::16, row_count::16, error_len::16,
           error::binary-size(error_len), rest::binary>>
       ) do
    {rows, <<>>} = decode_file_tree_rows(rest, row_count, [])

    %{
      visible?: (flags &&& 1) == 1,
      focused?: (flags &&& 2) == 2,
      selected_id: selected,
      root: root,
      width: width,
      error: error,
      rows: rows
    }
  end

  defp decode_file_tree(_payload), do: %{visible?: false, rows: [], width: 0}
  defp decode_file_tree_rows(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_file_tree_rows(
         <<_hash::32, flags::16, depth::8, _git::8, _errors::16, _warnings::16, _info::16,
           _hints::16, guide_count::8, guides::binary-size(guide_count), id_len::16,
           id::binary-size(id_len), path_len::16, _path::binary-size(path_len), rel_len::16,
           _rel::binary-size(rel_len), name_len::16, name::binary-size(name_len), icon_len::8,
           icon::binary-size(icon_len), editing_type::8, editing_len::16,
           editing::binary-size(editing_len), _icon_color::24, _heat_level::8, rest::binary>>,
         remaining,
         acc
       ) do
    row = %{
      id: id,
      name: if(editing_type == 0xFF, do: name, else: editing),
      icon: icon,
      depth: depth,
      guides: guides,
      directory?: (flags &&& 1) == 1,
      expanded?: (flags &&& 2) == 2,
      selected?: (flags &&& 4) == 4
    }

    decode_file_tree_rows(rest, remaining - 1, [row | acc])
  end

  defp apply_file_tree_selection(nil, payload),
    do: decode_file_tree(<<2, 0, 0, payload::binary, 0::16, 0::16, 0::16, 0::16>>)

  defp apply_file_tree_selection(
         file_tree,
         <<flags::8, selected_len::16, selected::binary-size(selected_len)>>
       ),
       do: %{
         file_tree
         | selected_id: selected,
           focused?: (flags &&& 1) == 1,
           rows: Enum.map(file_tree.rows, &%{&1 | selected?: &1.id == selected})
       }

  defp file_tree_row_text(row, width) do
    marker = if row.directory?, do: if(row.expanded?, do: "▾ ", else: "▸ "), else: "  "
    prefix = String.duplicate("  ", row.depth) <> marker <> row.icon <> " "
    text = prefix <> row.name

    text
    |> String.slice(0, max(width, 0))
    |> then(&if(row.selected?, do: "> " <> &1, else: "  " <> &1))
  end

  defp maybe_put_overlay_cursorline(window, flags, <<row::16, r::8, g::8, b::8>>)
       when (flags &&& 2) == 2,
       do: Map.put(window, :cursorline, %{row: row, bg_rgb: r <<< 16 ||| g <<< 8 ||| b})

  defp maybe_put_overlay_cursorline(window, _flags, _tail), do: window

  defp semantic_attrs_for_col(spans, col) do
    spans
    |> Enum.find(fn span -> col >= span.start_col and col < span.end_col end)
    |> case do
      nil -> []
      span -> decode_span_attrs(span.attrs)
    end
  end

  defp decode_span_attrs(attrs) do
    []
    |> then(fn acc -> if (attrs &&& 0x01) != 0, do: [:bold | acc], else: acc end)
    |> then(fn acc -> if (attrs &&& 0x02) != 0, do: [:underline | acc], else: acc end)
    |> then(fn acc -> if (attrs &&& 0x04) != 0, do: [:italic | acc], else: acc end)
    |> then(fn acc -> if (attrs &&& 0x08) != 0, do: [:reverse | acc], else: acc end)
    |> then(fn acc -> if (attrs &&& 0x10) != 0, do: [:strikethrough | acc], else: acc end)
    |> Enum.reverse()
  end

  defp maybe_reverse_attr(attrs, nil, _display_row, _col), do: attrs

  defp maybe_reverse_attr(attrs, selection, display_row, col) do
    if selected_cell?(selection, display_row, col) and :reverse not in attrs do
      [:reverse | attrs]
    else
      attrs
    end
  end

  defp selected_cell?(%{type: :line, start_row: start_row, end_row: end_row}, display_row, _col) do
    display_row >= start_row and display_row <= end_row
  end

  defp selected_cell?(
         %{start_row: start_row, start_col: start_col, end_row: end_row, end_col: end_col},
         display_row,
         col
       )
       when start_row == end_row do
    display_row == start_row and col >= start_col and col <= end_col
  end

  defp selected_cell?(
         %{start_row: start_row, start_col: start_col, end_row: _end_row},
         display_row,
         col
       )
       when display_row == start_row,
       do: col >= start_col

  defp selected_cell?(
         %{start_row: start_row, end_row: end_row, end_col: end_col},
         display_row,
         col
       )
       when display_row == end_row and start_row != end_row,
       do: col <= end_col

  defp selected_cell?(%{start_row: start_row, end_row: end_row}, display_row, _col),
    do: display_row > start_row and display_row < end_row

  defp selected_cell?(_selection, _display_row, _col), do: false

  defp graphemes_with_display_cols(graphemes) do
    {result, _display_col} =
      Enum.map_reduce(graphemes, 0, fn grapheme, display_col ->
        {{grapheme, display_col}, display_col + Unicode.display_width(grapheme)}
      end)

    result
  end

  defp decode_geometry_payload(payload) do
    {_window_id, total, content, text, gutter, clip, viewport_top, viewport_left, viewport_rows,
     viewport_cols, total_lines, visual_row_offset, total_visual_rows, line_number_width,
     sign_col_width, _hit_regions} = decode_geometry_tuple(payload)

    %{
      total_rect: total,
      content_rect: content,
      text_rect: text,
      gutter_rect: gutter,
      clip_rect: clip,
      viewport: %{
        top: viewport_top,
        left: viewport_left,
        rows: viewport_rows,
        cols: viewport_cols,
        total_lines: total_lines,
        visual_row_offset: visual_row_offset,
        total_visual_rows: total_visual_rows
      },
      gutter_metrics: %{line_number_width: line_number_width, sign_col_width: sign_col_width}
    }
  end

  defp decode_geometry_tuple(
         <<window_id::16, total::binary-size(8), content::binary-size(8), text::binary-size(8),
           gutter::binary-size(8), clip::binary-size(8), viewport_top::32, viewport_left::16,
           viewport_rows::16, viewport_cols::16, total_lines::32, visual_row_offset::16,
           total_visual_rows::32, line_number_width::16, sign_col_width::16, hit_count::8,
           rest::binary>>
       ) do
    {hit_regions, _rest} = skip_hit_regions(rest, hit_count, [])

    {window_id, decode_rect(total), decode_rect(content), decode_rect(text), decode_rect(gutter),
     decode_rect(clip), viewport_top, viewport_left, viewport_rows, viewport_cols, total_lines,
     visual_row_offset, total_visual_rows, line_number_width, sign_col_width, hit_regions}
  end

  defp decode_rect(<<row::16, col::16, width::16, height::16>>), do: {row, col, width, height}
  defp skip_hit_regions(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp skip_hit_regions(
         <<_kind::8, _rect::binary-size(8), _window_id::16, rest::binary>>,
         remaining,
         acc
       ),
       do: skip_hit_regions(rest, remaining - 1, acc)

  defp decode_cursor_shape(0), do: :block
  defp decode_cursor_shape(1), do: :beam
  defp decode_cursor_shape(2), do: :underline
  defp decode_cursor_shape(_), do: :block
  defp decode_row_type(0), do: :normal
  defp decode_row_type(1), do: :fold_start
  defp decode_row_type(2), do: :virtual_line
  defp decode_row_type(3), do: :block
  defp decode_row_type(4), do: :wrap_continuation
  defp decode_row_type(_), do: :normal
  defp decode_line_number_style(0), do: :hybrid
  defp decode_line_number_style(1), do: :absolute
  defp decode_line_number_style(2), do: :relative
  defp decode_line_number_style(_), do: :none
  defp decode_display_type(0), do: :normal
  defp decode_display_type(1), do: :fold_start
  defp decode_display_type(2), do: :fold_continuation
  defp decode_display_type(3), do: :wrap_continuation
  defp decode_display_type(4), do: :fold_open
  defp decode_display_type(_), do: :blank
  defp decode_sign_type(1), do: :git_added
  defp decode_sign_type(2), do: :git_modified
  defp decode_sign_type(3), do: :git_deleted
  defp decode_sign_type(4), do: :diag_error
  defp decode_sign_type(5), do: :diag_warning
  defp decode_sign_type(6), do: :diag_info
  defp decode_sign_type(7), do: :diag_hint
  defp decode_sign_type(8), do: :annotation
  defp decode_sign_type(9), do: :git_removed
  defp decode_sign_type(_), do: :none
  defp decode_mode(0), do: "NORMAL"
  defp decode_mode(1), do: "INSERT"
  defp decode_mode(2), do: "VISUAL"
  defp decode_mode(3), do: "COMMAND"
  defp decode_mode(_), do: ""

  @spec blank_grid(pos_integer(), pos_integer()) :: grid()
  defp blank_grid(width, height) do
    blank_cell = %{char: " ", fg: 0xFFFFFF, bg: 0x000000, attrs: []}

    for _row <- 1..height do
      for _col <- 1..width do
        blank_cell
      end
    end
  end
end
