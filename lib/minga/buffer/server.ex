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
  alias Minga.Filetype

  @typedoc "Options for starting a buffer server."
  @type start_opt ::
          {:file_path, String.t()}
          | {:content, String.t()}
          | {:name, GenServer.name()}
          | {:buffer_name, String.t()}
          | {:read_only, boolean()}
          | {:unlisted, boolean()}
          | {:persistent, boolean()}

  alias Minga.Buffer.State, as: BufState

  @typedoc "Internal state of the buffer server."
  @type state :: BufState.t()

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

  @doc "Force-saves the buffer, skipping mtime conflict detection."
  @spec force_save(GenServer.server()) :: :ok | {:error, term()}
  def force_save(server) do
    GenServer.call(server, :force_save)
  end

  @doc "Reloads the buffer from disk, preserving cursor position (clamped). Clears undo/redo."
  @spec reload(GenServer.server()) :: :ok | {:error, term()}
  def reload(server) do
    GenServer.call(server, :reload)
  end

  @doc "Saves the buffer content to a specific file path."
  @spec save_as(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def save_as(server, file_path) when is_binary(file_path) do
    GenServer.call(server, {:save_as, file_path})
  end

  @doc "Replaces the entire buffer content, pushing the old content onto the undo stack."
  @spec replace_content(GenServer.server(), String.t()) :: :ok
  def replace_content(server, new_content) when is_binary(new_content) do
    GenServer.call(server, {:replace_content, new_content})
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

  @doc "Returns the detected filetype atom for this buffer."
  @spec filetype(GenServer.server()) :: atom()
  def filetype(server) do
    GenServer.call(server, :filetype)
  end

  @doc "Returns the buffer name (e.g. `*Messages*`), or `nil` for file buffers."
  @spec buffer_name(GenServer.server()) :: String.t() | nil
  def buffer_name(server) do
    GenServer.call(server, :buffer_name)
  end

  @doc "Returns whether the buffer is read-only."
  @spec read_only?(GenServer.server()) :: boolean()
  def read_only?(server) do
    GenServer.call(server, :read_only?)
  end

  @doc "Returns whether the buffer is unlisted (hidden from buffer picker)."
  @spec unlisted?(GenServer.server()) :: boolean()
  def unlisted?(server) do
    GenServer.call(server, :unlisted?)
  end

  @doc "Returns whether the buffer is persistent (auto-recreated on kill)."
  @spec persistent?(GenServer.server()) :: boolean()
  def persistent?(server) do
    GenServer.call(server, :persistent?)
  end

  @doc "Appends text to the end of the buffer, bypassing read-only. For programmatic writes."
  @spec append(GenServer.server(), String.t()) :: :ok
  def append(server, text) when is_binary(text) do
    GenServer.call(server, {:append, text})
  end

  @typedoc "All data needed to render a single frame, fetched in one GenServer call."
  @type render_snapshot :: %{
          cursor: GapBuffer.position(),
          line_count: pos_integer(),
          lines: [String.t()],
          file_path: String.t() | nil,
          filetype: atom(),
          dirty: boolean(),
          name: String.t() | nil,
          read_only: boolean()
        }

  @doc """
  Returns all data needed to render a single frame in one GenServer call.

  Fetches cursor position, total line count, the visible line range starting at
  `first_line` (up to `count` lines), file path, and dirty flag atomically.
  This replaces 5 individual calls (cursor, line_count, get_lines, file_path,
  dirty?) with a single round-trip.
  """
  @spec render_snapshot(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          render_snapshot()
  def render_snapshot(server, first_line, count)
      when is_integer(first_line) and first_line >= 0 and is_integer(count) and count >= 0 do
    GenServer.call(server, {:render_snapshot, first_line, count})
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

  @doc "Returns the content and cursor position in a single GenServer call."
  @spec content_and_cursor(GenServer.server()) :: {String.t(), GapBuffer.position()}
  def content_and_cursor(server) do
    GenServer.call(server, :content_and_cursor)
  end

  @doc "Clears all content on the given line. Returns `{:ok, yanked_text}`."
  @spec clear_line(GenServer.server(), non_neg_integer()) :: {:ok, String.t()}
  def clear_line(server, line) when is_integer(line) and line >= 0 do
    GenServer.call(server, {:clear_line, line})
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
      {:ok, text, path, {mtime, size}} ->
        first_line = text |> String.split("\n", parts: 2) |> List.first("")
        filetype = Filetype.detect_from_content(path, first_line)

        state = %BufState{
          gap_buffer: GapBuffer.new(text),
          file_path: path,
          filetype: filetype,
          mtime: mtime,
          file_size: size,
          name: Keyword.get(opts, :buffer_name),
          read_only: Keyword.get(opts, :read_only, false),
          unlisted: Keyword.get(opts, :unlisted, false),
          persistent: Keyword.get(opts, :persistent, false)
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
        first_line = text |> String.split("\n", parts: 2) |> List.first("")
        filetype = Filetype.detect_from_content(file_path, first_line)

        {mtime, size} = file_stat_info(file_path)

        new_state = %{
          state
          | gap_buffer: GapBuffer.new(text),
            file_path: file_path,
            filetype: filetype,
            dirty: false,
            mtime: mtime,
            file_size: size
        }

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:insert_char, _char}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:insert_char, char}, _from, state) do
    new_buf = GapBuffer.insert_char(state.gap_buffer, char)
    {:reply, :ok, push_undo(state, new_buf) |> mark_dirty()}
  end

  def handle_call(:delete_before, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(:delete_before, _from, state) do
    new_buf = GapBuffer.delete_before(state.gap_buffer)

    if new_buf == state.gap_buffer do
      {:reply, :ok, state}
    else
      {:reply, :ok, push_undo(state, new_buf) |> mark_dirty()}
    end
  end

  def handle_call(:delete_at, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(:delete_at, _from, state) do
    new_buf = GapBuffer.delete_at(state.gap_buffer)

    if new_buf == state.gap_buffer do
      {:reply, :ok, state}
    else
      {:reply, :ok, push_undo(state, new_buf) |> mark_dirty()}
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
    {disk_mtime, disk_size} = file_stat_info(state.file_path)

    if file_changed_on_disk?(state, disk_mtime, disk_size) do
      {:reply, {:error, :file_changed}, state}
    else
      case write_file(state.file_path, GapBuffer.content(state.gap_buffer)) do
        :ok ->
          {new_mtime, new_size} = file_stat_info(state.file_path)
          {:reply, :ok, %{state | dirty: false, mtime: new_mtime, file_size: new_size}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:force_save, _from, %{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  def handle_call(:force_save, _from, state) do
    case write_file(state.file_path, GapBuffer.content(state.gap_buffer)) do
      :ok ->
        {new_mtime, new_size} = file_stat_info(state.file_path)
        {:reply, :ok, %{state | dirty: false, mtime: new_mtime, file_size: new_size}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reload, _from, %{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  def handle_call(:reload, _from, state) do
    case File.read(state.file_path) do
      {:ok, text} ->
        {line, col} = GapBuffer.cursor(state.gap_buffer)
        new_buf = GapBuffer.new(text)
        line_count = GapBuffer.line_count(new_buf)
        clamped_line = min(line, line_count - 1)

        clamped_col =
          case GapBuffer.lines(new_buf, clamped_line, 1) do
            [row] -> min(col, max(String.length(row) - 1, 0))
            _ -> 0
          end

        new_buf = GapBuffer.move_to(new_buf, {clamped_line, clamped_col})
        first_line = text |> String.split("\n", parts: 2) |> List.first("")
        filetype = Filetype.detect_from_content(state.file_path, first_line)

        {new_mtime, new_size} = file_stat_info(state.file_path)

        new_state = %{
          state
          | gap_buffer: new_buf,
            filetype: filetype,
            dirty: false,
            mtime: new_mtime,
            file_size: new_size,
            undo_stack: [],
            redo_stack: []
        }

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:save_as, file_path}, _from, state) do
    case write_file(file_path, GapBuffer.content(state.gap_buffer)) do
      :ok ->
        {new_mtime, new_size} = file_stat_info(file_path)

        {:reply, :ok,
         %{state | file_path: file_path, dirty: false, mtime: new_mtime, file_size: new_size}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace_content, _new_content}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:replace_content, new_content}, _from, state) do
    new_state = push_undo(state, state.gap_buffer)
    new_buf = GapBuffer.new(new_content)
    {:reply, :ok, mark_dirty(%{new_state | gap_buffer: new_buf})}
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

  def handle_call(:filetype, _from, state) do
    {:reply, state.filetype, state}
  end

  def handle_call(:buffer_name, _from, state) do
    {:reply, state.name, state}
  end

  def handle_call(:read_only?, _from, state) do
    {:reply, state.read_only, state}
  end

  def handle_call(:unlisted?, _from, state) do
    {:reply, state.unlisted, state}
  end

  def handle_call(:persistent?, _from, state) do
    {:reply, state.persistent, state}
  end

  def handle_call({:append, text}, _from, state) do
    content = GapBuffer.content(state.gap_buffer)
    new_content = content <> text
    new_buf = GapBuffer.new(new_content)
    # Move cursor to end
    line_count = GapBuffer.line_count(new_buf)
    last_line = max(0, line_count - 1)

    last_col =
      case GapBuffer.lines(new_buf, last_line, 1) do
        [row] -> max(0, String.length(row) - 1)
        _ -> 0
      end

    new_buf = GapBuffer.move_to(new_buf, {last_line, last_col})
    {:reply, :ok, %{state | gap_buffer: new_buf}}
  end

  def handle_call({:render_snapshot, first_line, count}, _from, state) do
    buf = state.gap_buffer

    snapshot = %{
      cursor: GapBuffer.cursor(buf),
      line_count: GapBuffer.line_count(buf),
      lines: GapBuffer.lines(buf, first_line, count),
      file_path: state.file_path,
      filetype: state.filetype,
      dirty: state.dirty,
      name: state.name,
      read_only: state.read_only
    }

    {:reply, snapshot, state}
  end

  def handle_call({:content_range, from_pos, to_pos}, _from, state) do
    text = GapBuffer.content_range(state.gap_buffer, from_pos, to_pos)
    {:reply, text, state}
  end

  def handle_call({:delete_range, _from_pos, _to_pos}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:delete_range, from_pos, to_pos}, _from, state) do
    new_buf = GapBuffer.delete_range(state.gap_buffer, from_pos, to_pos)

    if new_buf == state.gap_buffer do
      {:reply, :ok, state}
    else
      {:reply, :ok, push_undo(state, new_buf) |> mark_dirty()}
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

  def handle_call({:delete_lines, _start_line, _end_line}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:delete_lines, start_line, end_line}, _from, state) do
    new_buf = GapBuffer.delete_lines(state.gap_buffer, start_line, end_line)

    if new_buf == state.gap_buffer do
      {:reply, :ok, state}
    else
      {:reply, :ok, push_undo(state, new_buf) |> mark_dirty()}
    end
  end

  def handle_call(:content_and_cursor, _from, state) do
    {:reply, GapBuffer.content_and_cursor(state.gap_buffer), state}
  end

  def handle_call({:clear_line, _line}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:clear_line, line}, _from, state) do
    {yanked, new_buf} = GapBuffer.clear_line(state.gap_buffer, line)

    if new_buf == state.gap_buffer do
      {:reply, {:ok, yanked}, state}
    else
      {:reply, {:ok, yanked}, push_undo(state, new_buf) |> mark_dirty()}
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

  @typep file_meta :: {integer() | nil, non_neg_integer() | nil}

  @spec load_content(String.t() | nil, String.t()) ::
          {:ok, String.t(), String.t() | nil, file_meta()} | {:error, term()}
  defp load_content(nil, initial_content), do: {:ok, initial_content, nil, {nil, nil}}

  defp load_content(file_path, _initial_content) do
    case File.read(file_path) do
      {:ok, text} -> {:ok, text, file_path, file_stat_info(file_path)}
      {:error, :enoent} -> {:ok, "", file_path, {nil, nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Detects external changes by comparing mtime and file size.
  # Same mtime + same size = no change (covers same-second writes that don't alter size).
  # Different mtime OR different size = changed.
  @spec file_changed_on_disk?(BufState.t(), integer() | nil, non_neg_integer() | nil) ::
          boolean()
  defp file_changed_on_disk?(%{mtime: nil}, _disk_mtime, _disk_size), do: false
  defp file_changed_on_disk?(_state, nil, _disk_size), do: false

  defp file_changed_on_disk?(state, disk_mtime, disk_size) do
    disk_mtime > state.mtime or disk_size != state.file_size
  end

  @spec file_stat_info(String.t()) :: {integer() | nil, non_neg_integer() | nil}
  defp file_stat_info(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> {nil, nil}
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

  @spec mark_dirty(state()) :: state()
  defp mark_dirty(state), do: %{state | dirty: true}

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
