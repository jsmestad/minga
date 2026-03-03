defmodule Minga.API do
  @moduledoc """
  Public API for interacting with the editor from eval (`M-:`).

  Provides user-friendly functions for common editor operations. All
  functions default to the running `Minga.Editor` GenServer and the
  active buffer. Pass an explicit `editor` PID to target a different
  instance.

  ## Usage from eval

      # M-: Minga.API.insert("hello")
      # M-: Minga.API.save()
      # M-: Minga.API.cursor()
      # M-: Minga.API.open("lib/minga.ex")

  ## Error handling

  Functions return `{:ok, result}` or `{:error, reason}` where
  possible. They never raise on bad input.
  """

  alias Minga.Buffer.Server, as: BufferServer

  @typedoc "Editor GenServer reference."
  @type editor :: GenServer.server()

  @default_editor Minga.Editor

  # ── Buffer-level functions ──────────────────────────────────────────────────
  # These call BufferServer directly for speed (no Editor GenServer round-trip).

  @doc """
  Inserts text at the current cursor position in the active buffer.

  ## Examples

      Minga.API.insert("hello world")
      Minga.API.insert("\\n")  # insert a newline
  """
  @spec insert(String.t(), editor()) :: :ok | {:error, :no_buffer}
  def insert(text, editor \\ @default_editor) when is_binary(text) do
    with_buffer(editor, fn buf ->
      Enum.each(String.graphemes(text), &BufferServer.insert_char(buf, &1))
      :ok
    end)
  end

  @doc """
  Returns the full content of the active buffer.

  ## Examples

      {:ok, text} = Minga.API.content()
  """
  @spec content(editor()) :: {:ok, String.t()} | {:error, :no_buffer}
  def content(editor \\ @default_editor) do
    with_buffer(editor, fn buf ->
      {:ok, BufferServer.content(buf)}
    end)
  end

  @doc """
  Returns the current cursor position as `{line, col}` (0-indexed).

  ## Examples

      {:ok, {line, col}} = Minga.API.cursor()
  """
  @spec cursor(editor()) :: {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, :no_buffer}
  def cursor(editor \\ @default_editor) do
    with_buffer(editor, fn buf ->
      {:ok, BufferServer.cursor(buf)}
    end)
  end

  @doc """
  Moves the cursor to the given `{line, col}` position (0-indexed).

  ## Examples

      Minga.API.move_to(0, 0)   # go to start of file
      Minga.API.move_to(10, 5)  # line 11, column 6
  """
  @spec move_to(non_neg_integer(), non_neg_integer(), editor()) ::
          :ok | {:error, :no_buffer}
  def move_to(line, col, editor \\ @default_editor)
      when is_integer(line) and is_integer(col) and line >= 0 and col >= 0 do
    with_buffer(editor, fn buf ->
      BufferServer.move_to(buf, {line, col})
      :ok
    end)
  end

  @doc """
  Returns the number of lines in the active buffer.

  ## Examples

      {:ok, count} = Minga.API.line_count()
  """
  @spec line_count(editor()) :: {:ok, non_neg_integer()} | {:error, :no_buffer}
  def line_count(editor \\ @default_editor) do
    with_buffer(editor, fn buf ->
      {:ok, BufferServer.line_count(buf)}
    end)
  end

  # ── Editor-level functions ─────────────────────────────────────────────────
  # These go through the Editor GenServer for state coordination.

  @doc """
  Saves the active buffer to disk.

  ## Examples

      :ok = Minga.API.save()
  """
  @spec save(editor()) :: :ok | {:error, term()}
  def save(editor \\ @default_editor) do
    GenServer.call(editor, :api_save)
  end

  @doc """
  Opens a file in the editor. If the file is already open, switches to it.

  ## Examples

      :ok = Minga.API.open("lib/minga.ex")
  """
  @spec open(String.t(), editor()) :: :ok | {:error, term()}
  def open(file_path, editor \\ @default_editor) when is_binary(file_path) do
    GenServer.call(editor, {:open_file, file_path})
  end

  @doc """
  Logs a message to the `*Messages*` buffer.

  ## Examples

      Minga.API.message("Build completed!")
  """
  @spec message(String.t(), editor()) :: :ok
  def message(text, editor \\ @default_editor) when is_binary(text) do
    GenServer.call(editor, {:api_log_message, text})
  end

  @doc """
  Returns the current editor mode (e.g. `:normal`, `:insert`, `:visual`).

  ## Examples

      :normal = Minga.API.mode()
  """
  @spec mode(editor()) :: Minga.Mode.mode()
  def mode(editor \\ @default_editor) do
    GenServer.call(editor, :api_mode)
  end

  @doc """
  Executes an editor command by name.

  Commands are the same atoms used internally (e.g. `:save`, `:undo`,
  `:move_down`, `:buffer_next`). See `Minga.Command.Registry` for
  the full list.

  ## Examples

      Minga.API.execute(:undo)
      Minga.API.execute(:buffer_next)
      Minga.API.execute({:goto_line, 42})
  """
  @spec execute(Minga.Mode.command(), editor()) :: :ok
  def execute(command, editor \\ @default_editor) do
    GenServer.call(editor, {:api_execute_command, command})
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec with_buffer(editor(), (pid() -> result)) :: result | {:error, :no_buffer}
        when result: term()
  defp with_buffer(editor, fun) do
    case GenServer.call(editor, :api_active_buffer) do
      {:ok, buf} -> fun.(buf)
      {:error, _} = err -> err
    end
  end
end
