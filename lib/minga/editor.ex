defmodule Minga.Editor do
  @moduledoc """
  Editor orchestration GenServer.

  Ties together the buffer, port manager, and viewport. Receives
  input events from the Port Manager, dispatches them to the buffer,
  recomputes the visible region, and sends render commands back.

  For the walking skeleton (Phase 1), all input is treated as direct
  insertion — no modal FSM yet. Modal editing is added in Phase 2.
  """

  use GenServer

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Viewport
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol

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

  @typedoc "Internal state."
  @type state :: %{
          buffer: pid() | nil,
          port_manager: GenServer.server(),
          viewport: Viewport.t(),
          mode: :insert
        }

  # ── Client API ──

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

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    port_manager = Keyword.get(opts, :port_manager, PortManager)
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    buffer = Keyword.get(opts, :buffer)

    # Subscribe to input events from the port manager
    if is_pid(port_manager) or is_atom(port_manager) do
      try do
        PortManager.subscribe(port_manager)
      catch
        :exit, _ -> Logger.warning("Could not subscribe to port manager")
      end
    end

    state = %{
      buffer: buffer,
      port_manager: port_manager,
      viewport: Viewport.new(height, width),
      mode: :insert
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

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Key handling (Phase 1: insert-only mode) ──

  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp handle_key(%{buffer: nil} = state, _codepoint, _modifiers), do: state

  # Ctrl+S → save
  defp handle_key(state, ?s, mods) when band(mods, @ctrl) != 0 do
    case BufferServer.save(state.buffer) do
      :ok -> Logger.info("File saved")
      {:error, reason} -> Logger.error("Save failed: #{inspect(reason)}")
    end

    state
  end

  # Ctrl+Q → quit
  defp handle_key(state, ?q, mods) when band(mods, @ctrl) != 0 do
    Logger.info("Quitting editor")
    System.stop(0)
    # unreachable but required for type consistency
    state
  end

  # Arrow keys (using common terminal codepoints)
  # Up = 0xF700, Down = 0xF701, Left = 0xF702, Right = 0xF703
  # But we'll also handle standard VT sequences mapped by libvaxis
  defp handle_key(state, codepoint, _mods) when codepoint in [0xF700, 57416] do
    BufferServer.move(state.buffer, :up)
    state
  end

  defp handle_key(state, codepoint, _mods) when codepoint in [0xF701, 57424] do
    BufferServer.move(state.buffer, :down)
    state
  end

  defp handle_key(state, codepoint, _mods) when codepoint in [0xF702, 57419] do
    BufferServer.move(state.buffer, :left)
    state
  end

  defp handle_key(state, codepoint, _mods) when codepoint in [0xF703, 57421] do
    BufferServer.move(state.buffer, :right)
    state
  end

  # Backspace
  defp handle_key(state, codepoint, _mods) when codepoint in [8, 127] do
    BufferServer.delete_before(state.buffer)
    state
  end

  # Delete
  defp handle_key(state, 0xF728, _mods) do
    BufferServer.delete_at(state.buffer)
    state
  end

  # Enter
  defp handle_key(state, 13, _mods) do
    BufferServer.insert_char(state.buffer, "\n")
    state
  end

  # Tab
  defp handle_key(state, 9, _mods) do
    BufferServer.insert_char(state.buffer, "  ")
    state
  end

  # Printable characters
  defp handle_key(state, codepoint, _mods) when codepoint >= 32 and codepoint <= 0x10FFFF do
    case <<codepoint::utf8>> do
      char when is_binary(char) ->
        BufferServer.insert_char(state.buffer, char)
        state
    end
  rescue
    # Invalid codepoint
    ArgumentError -> state
  end

  # Ignore other keys
  defp handle_key(state, _codepoint, _mods), do: state

  # ── Rendering ──

  @spec do_render(state()) :: :ok
  defp do_render(%{buffer: nil} = state) do
    # Render empty screen with welcome message
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

    # Build render commands
    commands = [Protocol.encode_clear()]

    # Draw buffer lines
    line_commands =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line_text, screen_row} ->
        # Handle horizontal scrolling
        visible_text =
          if viewport.left > 0 do
            line_text
            |> String.graphemes()
            |> Enum.drop(viewport.left)
            |> Enum.take(viewport.cols)
            |> Enum.join()
          else
            String.slice(line_text, 0, viewport.cols)
          end

        Protocol.encode_draw(screen_row, 0, visible_text)
      end)

    # Draw tildes for empty lines past the buffer
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

    status_text =
      " #{file_name}#{dirty_marker}  #{cursor_line + 1}:#{cursor_col + 1}  #{line_count}L  -- INSERT --"

    status_row = viewport.rows - 1

    status_command =
      Protocol.encode_draw(status_row, 0, String.pad_trailing(status_text, viewport.cols),
        fg: 0x000000,
        bg: 0xCCCCCC,
        bold: true
      )

    # Cursor position (relative to viewport)
    cursor_row = cursor_line - viewport.top
    cursor_col_screen = cursor_col - viewport.left
    cursor_command = Protocol.encode_cursor(cursor_row, cursor_col_screen)

    all_commands =
      commands ++ line_commands ++ tilde_commands ++ [status_command, cursor_command, Protocol.encode_batch_end()]

    PortManager.send_commands(state.port_manager, all_commands)
    :ok
  end

  # ── Private ──

  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  defp start_buffer(file_path) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {BufferServer, file_path: file_path}
    )
  end
end
