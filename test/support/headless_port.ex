defmodule Minga.Test.HeadlessPort do
  @moduledoc """
  Virtual port manager that captures render commands into an in-memory
  screen grid. Drop-in replacement for `Minga.Port.Manager` in tests.

  Decodes `draw_text`, `set_cursor`, `set_cursor_shape`, `clear`, and
  `batch_end` commands from the editor's render pipeline into a queryable
  2D cell grid. The `batch_end` opcode marks a complete frame and notifies
  waiters, providing a natural synchronization point for test assertions.

  ## Usage

      {:ok, port} = HeadlessPort.start_link(width: 80, height: 24)
      # ... editor sends render commands ...
      screen = HeadlessPort.get_screen_text(port)
      assert Enum.at(screen, 0) =~ "hello"
  """

  use GenServer

  alias Minga.Port.Protocol

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

  defmodule State do
    @moduledoc false
    @enforce_keys [:width, :height]
    defstruct [
      :width,
      :height,
      grid: [],
      cursor: {0, 0},
      cursor_shape: :block,
      subscribers: [],
      waiters: [],
      frame_count: 0
    ]

    @type t :: %__MODULE__{
            width: pos_integer(),
            height: pos_integer(),
            grid: [[map()]],
            cursor: {non_neg_integer(), non_neg_integer()},
            cursor_shape: Minga.Port.Protocol.cursor_shape(),
            subscribers: [pid()],
            waiters: [{pid(), reference()}],
            frame_count: non_neg_integer()
          }
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the headless port."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

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

  @doc "Returns the total number of completed frames (batch_end count)."
  @spec frame_count(GenServer.server()) :: non_neg_integer()
  def frame_count(server) do
    GenServer.call(server, :frame_count)
  end

  @doc """
  Blocks until a new frame is rendered (batch_end received).
  Returns `:ok` or `{:error, :timeout}`.
  """
  @spec await_frame(GenServer.server(), timeout()) :: :ok | {:error, :timeout}
  def await_frame(server, timeout \\ 1000) do
    ref = make_ref()
    GenServer.cast(server, {:wait_for_frame, self(), ref})

    receive do
      {:frame_ready, ^ref} -> :ok
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
      grid: blank_grid(width, height)
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

  def handle_call(:ready?, _from, state) do
    {:reply, true, state}
  end

  # ── Screen query interface ──

  def handle_call(:get_screen_text, _from, state) do
    text =
      state.grid
      |> Enum.map(fn row ->
        row
        |> Enum.map(& &1.char)
        |> Enum.join()
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
      |> Enum.map(& &1.char)
      |> Enum.join()
      |> String.trim_trailing()

    {:reply, text, state}
  end

  def handle_call(:get_cursor, _from, state) do
    {:reply, state.cursor, state}
  end

  def handle_call(:get_cursor_shape, _from, state) do
    {:reply, state.cursor_shape, state}
  end

  def handle_call(:frame_count, _from, state) do
    {:reply, state.frame_count, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | grid: blank_grid(state.width, state.height), cursor: {0, 0}, frame_count: 0}}
  end

  # ── send_commands — the core render capture ──

  @impl true
  def handle_cast({:send_commands, commands}, state) do
    new_state = Enum.reduce(commands, state, &apply_command/2)
    {:noreply, new_state}
  end

  def handle_cast({:wait_for_frame, pid, ref}, state) do
    {:noreply, %{state | waiters: [{pid, ref} | state.waiters]}}
  end

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
  defp apply_command(cmd_binary, state) do
    case Protocol.decode_command(cmd_binary) do
      {:ok, :clear} ->
        %{state | grid: blank_grid(state.width, state.height)}

      {:ok, {:draw_text, %{row: row, col: col, fg: fg, bg: bg, attrs: attrs, text: text}}} ->
        draw_text(state, row, col, fg, bg, attrs, text)

      {:ok, {:set_cursor, row, col}} ->
        %{state | cursor: {row, col}}

      {:ok, {:set_cursor_shape, shape}} ->
        %{state | cursor_shape: shape}

      {:ok, :batch_end} ->
        # Notify all waiters that a frame is complete
        Enum.each(state.waiters, fn {pid, ref} ->
          send(pid, {:frame_ready, ref})
        end)

        %{state | waiters: [], frame_count: state.frame_count + 1}

      {:error, _reason} ->
        state
    end
  end

  @spec draw_text(State.t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), [atom()], String.t()) :: State.t()
  defp draw_text(state, row, col, fg, bg, attrs, text) do
    if row >= state.height do
      state
    else
      grid_row = Enum.at(state.grid, row)

      new_row =
        text
        |> String.graphemes()
        |> Enum.with_index(col)
        |> Enum.reduce(grid_row, fn {char, c}, acc ->
          if c < state.width do
            List.replace_at(acc, c, %{char: char, fg: fg, bg: bg, attrs: attrs})
          else
            acc
          end
        end)

      %{state | grid: List.replace_at(state.grid, row, new_row)}
    end
  end

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
