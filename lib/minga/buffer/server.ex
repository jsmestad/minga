defmodule Minga.Buffer.Server do
  @moduledoc """
  GenServer wrapping a `GapBuffer` with file I/O and dirty tracking.

  Each open file gets its own `Buffer.Server` process, managed by
  the `Buffer.Supervisor` (DynamicSupervisor). If a buffer process
  crashes, only that buffer is lost — all other buffers and the
  editor continue running.

  ## Examples

      {:ok, pid} = Minga.Buffer.Server.start_link(file_path: "README.md")
      :ok = Minga.Buffer.Server.insert_char(pid, "x")
      true = Minga.Buffer.Server.dirty?(pid)
      :ok = Minga.Buffer.Server.save(pid)
      false = Minga.Buffer.Server.dirty?(pid)
  """

  use GenServer

  alias Minga.Buffer.GapBuffer

  @typedoc "Options for starting a buffer server."
  @type start_opt ::
          {:file_path, String.t()}
          | {:content, String.t()}
          | {:name, GenServer.name()}

  @typedoc "Internal state of the buffer server."
  @type state :: %{
          gap_buffer: GapBuffer.t(),
          file_path: String.t() | nil,
          dirty: boolean(),
          undo_stack: [GapBuffer.t()],
          redo_stack: [GapBuffer.t()]
        }

  @max_undo_stack 1000

  # ── Client API ──

  @doc "Starts a buffer server. Pass `file_path:` to open a file, or `content:` for a scratch buffer."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Opens a file, replacing the current buffer content."
  @spec open(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def open(server, file_path) when is_binary(file_path) do
    GenServer.call(server, {:open, file_path})
  end

  @doc "Inserts a character at the current cursor position."
  @spec insert_char(GenServer.server(), String.t()) :: :ok
  def insert_char(server, char) when is_binary(char) do
    GenServer.call(server, {:insert_char, char})
  end

  @doc "Deletes the character before the cursor (backspace)."
  @spec delete_before(GenServer.server()) :: :ok
  def delete_before(server) do
    GenServer.call(server, :delete_before)
  end

  @doc "Deletes the character at the cursor (delete forward)."
  @spec delete_at(GenServer.server()) :: :ok
  def delete_at(server) do
    GenServer.call(server, :delete_at)
  end

  @doc "Moves the cursor in the given direction."
  @spec move(GenServer.server(), GapBuffer.direction()) :: :ok
  def move(server, direction) when direction in [:left, :right, :up, :down] do
    GenServer.call(server, {:move, direction})
  end

  @doc "Moves the cursor to an exact position."
  @spec move_to(GenServer.server(), GapBuffer.position()) :: :ok
  def move_to(server, {line, col} = pos)
      when is_integer(line) and line >= 0 and is_integer(col) and col >= 0 do
    GenServer.call(server, {:move_to, pos})
  end

  @doc "Saves the buffer content to the associated file."
  @spec save(GenServer.server()) :: :ok | {:error, term()}
  def save(server) do
    GenServer.call(server, :save)
  end

  @doc "Saves the buffer content to a specific file path."
  @spec save_as(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def save_as(server, file_path) when is_binary(file_path) do
    GenServer.call(server, {:save_as, file_path})
  end

  @doc "Returns the full text content of the buffer."
  @spec content(GenServer.server()) :: String.t()
  def content(server) do
    GenServer.call(server, :content)
  end

  @doc "Returns a range of lines from the buffer."
  @spec get_lines(GenServer.server(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  def get_lines(server, start, count)
      when is_integer(start) and start >= 0 and is_integer(count) and count >= 0 do
    GenServer.call(server, {:get_lines, start, count})
  end

  @doc "Returns the current cursor position."
  @spec cursor(GenServer.server()) :: GapBuffer.position()
  def cursor(server) do
    GenServer.call(server, :cursor)
  end

  @doc "Returns the total line count."
  @spec line_count(GenServer.server()) :: pos_integer()
  def line_count(server) do
    GenServer.call(server, :line_count)
  end

  @doc "Returns whether the buffer has unsaved changes."
  @spec dirty?(GenServer.server()) :: boolean()
  def dirty?(server) do
    GenServer.call(server, :dirty?)
  end

  @doc "Returns the file path associated with this buffer, if any."
  @spec file_path(GenServer.server()) :: String.t() | nil
  def file_path(server) do
    GenServer.call(server, :file_path)
  end

  @doc "Returns the text between two positions (from_pos inclusive, to_pos exclusive)."
  @spec content_range(GenServer.server(), GapBuffer.position(), GapBuffer.position()) ::
          String.t()
  def content_range(server, from_pos, to_pos) do
    GenServer.call(server, {:content_range, from_pos, to_pos})
  end

  @doc "Deletes the text between two positions (from_pos inclusive, to_pos exclusive), placing the cursor at the start of the range."
  @spec delete_range(GenServer.server(), GapBuffer.position(), GapBuffer.position()) :: :ok
  def delete_range(server, from_pos, to_pos) do
    GenServer.call(server, {:delete_range, from_pos, to_pos})
  end

  @doc """
  Returns the text in the range [start_pos, end_pos] inclusive.
  Positions are sorted automatically.
  """
  @spec get_range(GenServer.server(), GapBuffer.position(), GapBuffer.position()) :: String.t()
  def get_range(server, start_pos, end_pos) do
    GenServer.call(server, {:get_range, start_pos, end_pos})
  end

  @doc """
  Returns the joined text of lines [start_line, end_line] inclusive (no trailing newline).
  """
  @spec get_lines_content(GenServer.server(), non_neg_integer(), non_neg_integer()) :: String.t()
  def get_lines_content(server, start_line, end_line)
      when is_integer(start_line) and start_line >= 0 and
             is_integer(end_line) and end_line >= 0 do
    GenServer.call(server, {:get_lines_content, start_line, end_line})
  end

  @doc "Undoes the last mutation, restoring the previous buffer state."
  @spec undo(GenServer.server()) :: :ok
  def undo(server) do
    GenServer.call(server, :undo)
  end

  @doc "Redoes the last undone mutation."
  @spec redo(GenServer.server()) :: :ok
  def redo(server) do
    GenServer.call(server, :redo)
  end

  @doc "Deletes lines [start_line, end_line] inclusive. Cursor lands at the first remaining line."
  @spec delete_lines(GenServer.server(), non_neg_integer(), non_neg_integer()) :: :ok
  def delete_lines(server, start_line, end_line)
      when is_integer(start_line) and start_line >= 0 and
             is_integer(end_line) and end_line >= 0 do
    GenServer.call(server, {:delete_lines, start_line, end_line})
  end

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    file_path = Keyword.get(opts, :file_path)
    initial_content = Keyword.get(opts, :content, "")

    case load_content(file_path, initial_content) do
      {:ok, text, path} ->
        state = %{
          gap_buffer: GapBuffer.new(text),
          file_path: path,
          dirty: false,
          undo_stack: [],
          redo_stack: []
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:open, file_path}, _from, state) do
    case File.read(file_path) do
      {:ok, text} ->
        new_state = %{
          state
          | gap_buffer: GapBuffer.new(text),
            file_path: file_path,
            dirty: false
        }

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:insert_char, char}, _from, state) do
    new_buf = GapBuffer.insert_char(state.gap_buffer, char)
    {:reply, :ok, push_undo(state, new_buf) |> Map.put(:dirty, true)}
  end

  def handle_call(:delete_before, _from, state) do
    new_buf = GapBuffer.delete_before(state.gap_buffer)

    if new_buf == state.gap_buffer do
      {:reply, :ok, state}
    else
      {:reply, :ok, push_undo(state, new_buf) |> Map.put(:dirty, true)}
    end
  end

  def handle_call(:delete_at, _from, state) do
    new_buf = GapBuffer.delete_at(state.gap_buffer)

    if new_buf == state.gap_buffer do
      {:reply, :ok, state}
    else
      {:reply, :ok, push_undo(state, new_buf) |> Map.put(:dirty, true)}
    end
  end

  def handle_call({:move, direction}, _from, state) do
    new_buf = GapBuffer.move(state.gap_buffer, direction)
    {:reply, :ok, %{state | gap_buffer: new_buf}}
  end

  def handle_call({:move_to, pos}, _from, state) do
    new_buf = GapBuffer.move_to(state.gap_buffer, pos)
    {:reply, :ok, %{state | gap_buffer: new_buf}}
  end

  def handle_call(:save, _from, %{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  def handle_call(:save, _from, state) do
    case write_file(state.file_path, GapBuffer.content(state.gap_buffer)) do
      :ok -> {:reply, :ok, %{state | dirty: false}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:save_as, file_path}, _from, state) do
    case write_file(file_path, GapBuffer.content(state.gap_buffer)) do
      :ok ->
        {:reply, :ok, %{state | file_path: file_path, dirty: false}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:content, _from, state) do
    {:reply, GapBuffer.content(state.gap_buffer), state}
  end

  def handle_call({:get_lines, start, count}, _from, state) do
    {:reply, GapBuffer.lines(state.gap_buffer, start, count), state}
  end

  def handle_call(:cursor, _from, state) do
    {:reply, GapBuffer.cursor(state.gap_buffer), state}
  end

  def handle_call(:line_count, _from, state) do
    {:reply, GapBuffer.line_count(state.gap_buffer), state}
  end

  def handle_call(:dirty?, _from, state) do
    {:reply, state.dirty, state}
  end

  def handle_call(:file_path, _from, state) do
    {:reply, state.file_path, state}
  end

  def handle_call({:content_range, from_pos, to_pos}, _from, state) do
    text = GapBuffer.content_range(state.gap_buffer, from_pos, to_pos)
    {:reply, text, state}
  end

  def handle_call({:delete_range, from_pos, to_pos}, _from, state) do
    new_buf = GapBuffer.delete_range(state.gap_buffer, from_pos, to_pos)

    if new_buf == state.gap_buffer do
      {:reply, :ok, state}
    else
      {:reply, :ok, push_undo(state, new_buf) |> Map.put(:dirty, true)}
    end
  end

  def handle_call({:get_range, start_pos, end_pos}, _from, state) do
    result = GapBuffer.get_range(state.gap_buffer, start_pos, end_pos)
    {:reply, result, state}
  end

  def handle_call({:get_lines_content, start_line, end_line}, _from, state) do
    result = GapBuffer.get_lines_content(state.gap_buffer, start_line, end_line)
    {:reply, result, state}
  end

  def handle_call({:delete_lines, start_line, end_line}, _from, state) do
    new_buf = GapBuffer.delete_lines(state.gap_buffer, start_line, end_line)

    if new_buf == state.gap_buffer do
      {:reply, :ok, state}
    else
      {:reply, :ok, push_undo(state, new_buf) |> Map.put(:dirty, true)}
    end
  end

  def handle_call(:undo, _from, state) do
    case state.undo_stack do
      [] ->
        {:reply, :ok, state}

      [prev_buf | rest_undo] ->
        new_state = %{
          state
          | gap_buffer: prev_buf,
            undo_stack: rest_undo,
            redo_stack: [state.gap_buffer | state.redo_stack],
            dirty: true
        }

        {:reply, :ok, new_state}
    end
  end

  def handle_call(:redo, _from, state) do
    case state.redo_stack do
      [] ->
        {:reply, :ok, state}

      [next_buf | rest_redo] ->
        new_state = %{
          state
          | gap_buffer: next_buf,
            redo_stack: rest_redo,
            undo_stack: [state.gap_buffer | state.undo_stack],
            dirty: true
        }

        {:reply, :ok, new_state}
    end
  end

  # ── Private ──

  @spec load_content(String.t() | nil, String.t()) ::
          {:ok, String.t(), String.t() | nil} | {:error, term()}
  defp load_content(nil, initial_content), do: {:ok, initial_content, nil}

  defp load_content(file_path, _initial_content) do
    case File.read(file_path) do
      {:ok, text} -> {:ok, text, file_path}
      {:error, :enoent} -> {:ok, "", file_path}
      {:error, reason} -> {:error, reason}
    end
  end

  # Pushes the current gap_buffer onto the undo stack (capped at @max_undo_stack),
  # sets the new gap_buffer, and clears the redo stack.
  @spec push_undo(state(), GapBuffer.t()) :: state()
  defp push_undo(state, new_buf) do
    new_undo =
      [state.gap_buffer | state.undo_stack]
      |> Enum.take(@max_undo_stack)

    %{state | gap_buffer: new_buf, undo_stack: new_undo, redo_stack: []}
  end

  @spec write_file(String.t(), String.t()) :: :ok | {:error, term()}
  defp write_file(file_path, content) do
    file_path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok -> File.write(file_path, content)
      error -> error
    end
  end
end
