defmodule Minga.Buffer.Server do
  @moduledoc """
  GenServer wrapping a `Document` with file I/O and dirty tracking.

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

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.Unicode
  alias Minga.Config.Options
  alias Minga.Filetype
  alias Minga.NavigableContent.BufferSnapshot
  alias Minga.Scroll

  alias Minga.Buffer.State, as: BufState

  @typedoc "Options for starting a buffer server."
  @type start_opt ::
          {:file_path, String.t()}
          | {:content, String.t()}
          | {:name, GenServer.name()}
          | {:buffer_name, String.t()}
          | {:buffer_type, BufState.buffer_type()}
          | {:filetype, atom()}
          | {:read_only, boolean()}
          | {:unlisted, boolean()}
          | {:persistent, boolean()}

  @typedoc "Internal state of the buffer server."
  @type state :: BufState.t()

  # ── Client API ──

  @doc "Starts a buffer server. Pass `file_path:` to open a file, or `content:` for an unnamed buffer."
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

  @doc """
  Inserts a string at the current cursor position.

  Each character is inserted sequentially, advancing the cursor.
  """
  @spec insert_text(GenServer.server(), String.t()) :: :ok
  def insert_text(server, text) when is_binary(text) do
    GenServer.call(server, {:insert_text, text})
  end

  @doc """
  Replaces a range of text with new text.

  Moves to the start of the range, deletes the range, then inserts the
  new text. Used by LSP text edits.
  """
  @spec apply_text_edit(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: :ok
  def apply_text_edit(server, start_line, start_col, end_line, end_col, new_text) do
    GenServer.call(
      server,
      {:apply_text_edit, {start_line, start_col}, {end_line, end_col}, new_text}
    )
  end

  @typedoc "A single text edit: `{start_pos, end_pos, replacement_text}`."
  @type text_edit ::
          {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()},
           String.t()}

  @doc """
  Applies multiple text edits in a single GenServer call.

  All edits are applied to the Document sequentially, but only one undo
  entry is pushed and the version bumps once. Edits should be sorted in
  reverse document order (last position first) so earlier offsets remain
  valid as later text is replaced. If edits are not pre-sorted, this
  function sorts them automatically.

  Used by AI/LSP batch operations to avoid N round-trips and N undo entries.
  """
  @spec apply_text_edits(GenServer.server(), [text_edit()]) :: :ok
  def apply_text_edits(server, edits) when is_list(edits) do
    GenServer.call(server, {:apply_text_edits, edits})
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
  @spec move(GenServer.server(), Document.direction()) :: :ok
  def move(server, direction) when direction in [:left, :right, :up, :down] do
    GenServer.call(server, {:move, direction})
  end

  @doc "Moves the cursor to an exact position."
  @spec move_to(GenServer.server(), Document.position()) :: :ok
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

  @doc "Replaces buffer content bypassing read-only. For programmatic panel updates."
  @spec replace_content_force(GenServer.server(), String.t()) :: :ok
  def replace_content_force(server, new_content) when is_binary(new_content) do
    GenServer.call(server, {:replace_content_force, new_content})
  end

  @doc "Returns the full text content of the buffer."
  @spec content(GenServer.server()) :: String.t()
  def content(server) do
    GenServer.call(server, :content)
  end

  @doc "Returns the byte offset for the start of a given line."
  @spec byte_offset_for_line(GenServer.server(), non_neg_integer()) :: non_neg_integer()
  def byte_offset_for_line(server, line) when is_integer(line) and line >= 0 do
    GenServer.call(server, {:byte_offset_for_line, line})
  end

  @doc "Returns a range of lines from the buffer."
  @spec get_lines(GenServer.server(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  def get_lines(server, start, count)
      when is_integer(start) and start >= 0 and is_integer(count) and count >= 0 do
    GenServer.call(server, {:get_lines, start, count})
  end

  @doc "Returns the current cursor position."
  @spec cursor(GenServer.server()) :: Document.position()
  def cursor(server) do
    GenServer.call(server, :cursor)
  end

  @doc "Sets the cursor to an absolute position. Clamped to buffer bounds."
  @spec set_cursor(GenServer.server(), Document.position()) :: :ok
  def set_cursor(server, {line, col}) when is_integer(line) and is_integer(col) do
    GenServer.call(server, {:set_cursor, {line, col}})
  end

  @doc "Moves the cursor in the given direction."
  @spec move_cursor(GenServer.server(), :up | :down | :left | :right) :: :ok
  def move_cursor(server, direction) when direction in [:up, :down, :left, :right] do
    GenServer.call(server, {:move_cursor, direction})
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

  @doc "Returns the buffer's mutation version counter (increments on every content change)."
  @spec version(GenServer.server()) :: non_neg_integer()
  def version(server) do
    GenServer.call(server, :version)
  end

  @doc """
  Returns and clears pending edit deltas accumulated since the last flush.

  Used by `HighlightSync` to send incremental content updates to the
  parser process instead of full file content.
  """
  @spec flush_edits(GenServer.server()) :: [EditDelta.t()]
  def flush_edits(server) do
    GenServer.call(server, :flush_edits)
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

  @doc "Returns the buffer's type (`:file`, `:nofile`, `:nowrite`, `:prompt`, `:terminal`)."
  @spec buffer_type(GenServer.server()) :: BufState.buffer_type()
  def buffer_type(server) do
    GenServer.call(server, :buffer_type)
  end

  # ── Buffer-local options ──

  @doc """
  Returns a buffer-local option value using the resolution chain:
  buffer-local → filetype override → global default.

  Buffer-local options take highest priority. If no local override
  exists, the filetype default from `Config.Options` is checked, then
  the global default. This gives each buffer its own isolated option
  state while inheriting sensible defaults.
  """
  @spec get_option(GenServer.server(), atom()) :: term()
  def get_option(server, name) when is_atom(name) do
    GenServer.call(server, {:get_option, name})
  end

  @doc """
  Sets a buffer-local option override. Only affects this buffer.

  The value is validated against the same type rules as
  `Config.Options.set/2`. Returns `{:ok, value}` on success or
  `{:error, reason}` if the value is invalid.
  """
  @spec set_option(GenServer.server(), atom(), term()) ::
          {:ok, term()} | {:error, String.t()}
  def set_option(server, name, value) when is_atom(name) do
    GenServer.call(server, {:set_option, name, value})
  end

  @doc """
  Returns all buffer-local option overrides (not the resolved values,
  just the overrides set on this buffer).
  """
  @spec local_options(GenServer.server()) :: %{atom() => term()}
  def local_options(server) do
    GenServer.call(server, :local_options)
  end

  @doc "Appends text to the end of the buffer, bypassing read-only. For programmatic writes."
  @spec append(GenServer.server(), String.t()) :: :ok
  def append(server, text) when is_binary(text) do
    GenServer.call(server, {:append, text})
  end

  alias Minga.Buffer.RenderSnapshot

  @doc """
  Returns all data needed to render a single frame in one GenServer call.

  Fetches cursor position, total line count, the visible line range starting at
  `first_line` (up to `count` lines), file path, and dirty flag atomically.
  This replaces 5 individual calls (cursor, line_count, get_lines, file_path,
  dirty?) with a single round-trip.
  """
  @spec render_snapshot(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          RenderSnapshot.t()
  def render_snapshot(server, first_line, count)
      when is_integer(first_line) and first_line >= 0 and is_integer(count) and count >= 0 do
    GenServer.call(server, {:render_snapshot, first_line, count})
  end

  @doc "Returns the text between two positions (from_pos inclusive, to_pos exclusive)."
  @spec content_range(GenServer.server(), Document.position(), Document.position()) ::
          String.t()
  def content_range(server, from_pos, to_pos) do
    GenServer.call(server, {:content_range, from_pos, to_pos})
  end

  @doc "Deletes the text between two positions (from_pos inclusive, to_pos exclusive), placing the cursor at the start of the range."
  @spec delete_range(GenServer.server(), Document.position(), Document.position()) :: :ok
  def delete_range(server, from_pos, to_pos) do
    GenServer.call(server, {:delete_range, from_pos, to_pos})
  end

  @doc """
  Returns the text in the range [start_pos, end_pos] inclusive.
  Positions are sorted automatically.
  """
  @spec get_range(GenServer.server(), Document.position(), Document.position()) :: String.t()
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
  @spec content_and_cursor(GenServer.server()) :: {String.t(), Document.position()}
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

  @doc """
  Resets the undo coalescing timer so the next mutation starts a fresh
  undo entry. Call this at undo boundaries like mode transitions (e.g.,
  leaving insert mode).
  """
  @spec break_undo_coalescing(GenServer.server()) :: :ok
  def break_undo_coalescing(server) do
    GenServer.call(server, :break_undo_coalescing)
  end

  @doc "Deletes lines [start_line, end_line] inclusive. Cursor lands at the first remaining line."
  @spec delete_lines(GenServer.server(), non_neg_integer(), non_neg_integer()) :: :ok
  def delete_lines(server, start_line, end_line)
      when is_integer(start_line) and start_line >= 0 and
             is_integer(end_line) and end_line >= 0 do
    GenServer.call(server, {:delete_lines, start_line, end_line})
  end

  @doc """
  Returns the underlying `Document.t()` struct for pure computation.

  Use this to batch multiple reads into a single GenServer call. Perform
  all calculations on the returned struct, then apply the result with
  `move_to/2` (cursor-only changes) or `apply_snapshot/2` (content changes).
  """
  @spec snapshot(GenServer.server()) :: Document.t()
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Replaces the internal gap buffer with a new one, pushing the old buffer
  onto the undo stack and marking the buffer dirty.

  Use this after performing a batch of pure `Document` operations on a
  snapshot. Only call this when content has actually changed; for cursor-only
  changes use `move_to/2` instead.
  """
  @spec apply_snapshot(GenServer.server(), Document.t()) :: :ok
  def apply_snapshot(server, %Document{} = new_buf) do
    GenServer.call(server, {:apply_snapshot, new_buf})
  end

  @doc """
  Takes a snapshot wrapped in a `BufferSnapshot` struct for use with the
  `NavigableContent` protocol. Includes the given scroll state so that
  scroll operations can be composed with cursor and content changes.

  After operating on the snapshot through `NavigableContent`, apply the
  result back with `apply_navigable_snapshot/2`.
  """
  @spec navigable_snapshot(GenServer.server(), Scroll.t()) :: BufferSnapshot.t()
  def navigable_snapshot(server, %Scroll{} = scroll) do
    doc = snapshot(server)
    BufferSnapshot.new(doc, scroll)
  end

  @doc """
  Applies a `BufferSnapshot` back to the server, updating the document
  and returning the updated scroll state.

  Only writes the document back if content or cursor changed. Returns
  the scroll state from the snapshot for the caller to store.
  """
  @spec apply_navigable_snapshot(GenServer.server(), BufferSnapshot.t()) :: Scroll.t()
  def apply_navigable_snapshot(server, %BufferSnapshot{document: new_doc, scroll: scroll}) do
    apply_snapshot(server, new_doc)
    scroll
  end

  # ── Decoration API ──

  @doc """
  Adds a highlight range decoration to the buffer.

  Returns the decoration ID (a reference) for later removal.
  See `Minga.Buffer.Decorations.add_highlight/4` for options.
  """
  @spec add_highlight(
          GenServer.server(),
          Decorations.highlight_range_pos(),
          Decorations.highlight_range_pos(),
          keyword()
        ) :: reference()
  def add_highlight(server, start_pos, end_pos, opts) do
    GenServer.call(server, {:add_highlight, start_pos, end_pos, opts})
  end

  @doc "Removes a highlight range by ID."
  @spec remove_highlight(GenServer.server(), reference()) :: :ok
  def remove_highlight(server, id) do
    GenServer.call(server, {:remove_highlight, id})
  end

  @doc "Removes all highlight ranges in a group."
  @spec remove_highlight_group(GenServer.server(), atom()) :: :ok
  def remove_highlight_group(server, group) when is_atom(group) do
    GenServer.call(server, {:remove_highlight_group, group})
  end

  @doc """
  Executes a batch of decoration operations. The function receives and
  returns a `Decorations` struct. All operations are applied with a
  single tree rebuild.
  """
  @spec batch_decorations(GenServer.server(), (Decorations.t() -> Decorations.t())) :: :ok
  def batch_decorations(server, fun) when is_function(fun, 1) do
    GenServer.call(server, {:batch_decorations, fun})
  end

  @doc """
  Adds a virtual text decoration to the buffer.

  Returns the decoration ID (a reference) for later removal.
  See `Minga.Buffer.Decorations.add_virtual_text/3` for options.
  """
  @spec add_virtual_text(GenServer.server(), Decorations.highlight_range_pos(), keyword()) ::
          reference()
  def add_virtual_text(server, anchor, opts) do
    GenServer.call(server, {:add_virtual_text, anchor, opts})
  end

  @doc "Removes a virtual text decoration by ID."
  @spec remove_virtual_text(GenServer.server(), reference()) :: :ok
  def remove_virtual_text(server, id) do
    GenServer.call(server, {:remove_virtual_text, id})
  end

  @doc "Returns the decorations struct for read-only access (e.g., by the render pipeline)."
  @spec decorations(GenServer.server()) :: Decorations.t()
  def decorations(server) do
    GenServer.call(server, :decorations)
  end

  @doc "Returns the decorations version for cheap change detection."
  @spec decorations_version(GenServer.server()) :: non_neg_integer()
  def decorations_version(server) do
    GenServer.call(server, :decorations_version)
  end

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    # Tune GC for buffer processes: they churn binaries during edits and
    # content queries. Frequent full sweeps prevent binary ref buildup;
    # larger initial heap reduces grow-and-GC cycles for large files.
    Process.flag(:fullsweep_after, 20)
    Process.flag(:min_heap_size, 4096)

    file_path = Keyword.get(opts, :file_path)
    initial_content = Keyword.get(opts, :content, "")

    case load_content(file_path, initial_content) do
      {:ok, text, path, {mtime, size}} ->
        filetype =
          case Keyword.get(opts, :filetype) do
            nil ->
              first_line = text |> String.split("\n", parts: 2) |> List.first("")
              Filetype.detect_from_content(path, first_line)

            ft when is_atom(ft) ->
              ft
          end

        buffer_type = Keyword.get(opts, :buffer_type, :file)

        # :nofile buffers are implicitly read-only unless explicitly overridden
        read_only =
          case {buffer_type, Keyword.get(opts, :read_only)} do
            {:nofile, nil} -> true
            {:nofile, explicit} -> explicit
            {_, nil} -> false
            {_, explicit} -> explicit
          end

        state = %BufState{
          document: Document.new(text),
          file_path: path,
          filetype: filetype,
          buffer_type: buffer_type,
          mtime: mtime,
          file_size: size,
          name: Keyword.get(opts, :buffer_name),
          read_only: read_only,
          unlisted: Keyword.get(opts, :unlisted, false),
          persistent: Keyword.get(opts, :persistent, false),
          options: seed_options(filetype)
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
          | document: Document.new(text),
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
    old_doc = state.document
    new_buf = Document.insert_char(old_doc, char)

    delta =
      EditDelta.insertion(
        byte_size(old_doc.before),
        Document.cursor(old_doc),
        char,
        Document.cursor(new_buf)
      )

    state = push_undo(state, new_buf) |> mark_dirty() |> record_edit(delta)
    {:reply, :ok, state}
  end

  def handle_call({:insert_text, _text}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:insert_text, text}, _from, state) do
    old_doc = state.document
    new_doc = Document.insert_text(old_doc, text)

    delta =
      EditDelta.insertion(
        byte_size(old_doc.before),
        Document.cursor(old_doc),
        text,
        Document.cursor(new_doc)
      )

    state = push_undo(state, new_doc) |> mark_dirty() |> record_edit(delta)
    {:reply, :ok, state}
  end

  def handle_call(
        {:apply_text_edit, _from_pos, _to_pos, _text},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:apply_text_edit, from_pos, to_pos, new_text}, _from, state) do
    old_content = Document.content(state.document)
    start_byte = byte_offset_at(old_content, from_pos)
    old_end_byte = byte_offset_at(old_content, to_pos)

    doc = Document.move_to(state.document, from_pos)
    doc = Document.delete_range(doc, from_pos, to_pos)
    doc = Document.insert_text(doc, new_text)

    new_end_pos = advance_position(from_pos, new_text)

    delta =
      EditDelta.replacement(start_byte, old_end_byte, from_pos, to_pos, new_text, new_end_pos)

    {:reply, :ok, push_undo(state, doc) |> mark_dirty() |> record_edit(delta)}
  end

  def handle_call({:apply_text_edits, _edits}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:apply_text_edits, []}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:apply_text_edits, edits}, _from, state) do
    # Sort edits in reverse document order so earlier offsets stay valid
    # as we apply edits from the end of the document backward.
    sorted =
      Enum.sort(edits, fn {from_a, _, _}, {from_b, _, _} ->
        from_a >= from_b
      end)

    doc =
      Enum.reduce(sorted, state.document, fn {from_pos, to_pos, new_text}, doc ->
        doc
        |> Document.move_to(from_pos)
        |> Document.delete_range(from_pos, to_pos)
        |> Document.insert_text(new_text)
      end)

    # Multi-edit batches are complex to delta-track (offsets shift between
    # edits). Clear pending edits to force a full content sync.
    {:reply, :ok, push_undo(state, doc) |> mark_dirty() |> clear_edits()}
  end

  def handle_call(:delete_before, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(:delete_before, _from, state) do
    old_doc = state.document
    new_buf = Document.delete_before(old_doc)

    if new_buf == old_doc do
      {:reply, :ok, state}
    else
      new_cursor = Document.cursor(new_buf)

      delta =
        EditDelta.deletion(
          byte_size(new_buf.before),
          byte_size(old_doc.before),
          new_cursor,
          Document.cursor(old_doc)
        )

      {:reply, :ok, push_undo(state, new_buf) |> mark_dirty() |> record_edit(delta)}
    end
  end

  def handle_call(:delete_at, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(:delete_at, _from, state) do
    old_doc = state.document
    new_buf = Document.delete_at(old_doc)

    if new_buf == old_doc do
      {:reply, :ok, state}
    else
      # delete_at removes the char after cursor; cursor position stays the same
      old_end_byte =
        byte_size(old_doc.before) + byte_size(old_doc.after) - byte_size(new_buf.after)

      old_content = Document.content(old_doc)
      # Compute old_end_position from the removed text
      removed =
        binary_part(
          old_content,
          byte_size(old_doc.before),
          old_end_byte - byte_size(old_doc.before)
        )

      old_end_pos = advance_position(Document.cursor(old_doc), removed)

      delta =
        EditDelta.deletion(
          byte_size(old_doc.before),
          old_end_byte,
          Document.cursor(old_doc),
          old_end_pos
        )

      {:reply, :ok, push_undo(state, new_buf) |> mark_dirty() |> record_edit(delta)}
    end
  end

  def handle_call({:move, direction}, _from, state) do
    new_buf = Document.move(state.document, direction)
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call({:move_to, pos}, _from, state) do
    new_buf = Document.move_to(state.document, pos)
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call(:save, _from, %{buffer_type: bt} = state) when bt in [:nofile, :nowrite] do
    {:reply, {:error, :buffer_not_saveable}, state}
  end

  def handle_call(:save, _from, %{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  def handle_call(:save, _from, state) do
    {disk_mtime, disk_size} = file_stat_info(state.file_path)

    if file_changed_on_disk?(state, disk_mtime, disk_size) do
      {:reply, {:error, :file_changed}, state}
    else
      case write_file(state.file_path, Document.content(state.document)) do
        :ok ->
          {new_mtime, new_size} = file_stat_info(state.file_path)
          {:reply, :ok, mark_saved(%{state | mtime: new_mtime, file_size: new_size})}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:force_save, _from, %{buffer_type: bt} = state)
      when bt in [:nofile, :nowrite] do
    {:reply, {:error, :buffer_not_saveable}, state}
  end

  def handle_call(:force_save, _from, %{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  def handle_call(:force_save, _from, state) do
    case write_file(state.file_path, Document.content(state.document)) do
      :ok ->
        {new_mtime, new_size} = file_stat_info(state.file_path)
        {:reply, :ok, mark_saved(%{state | mtime: new_mtime, file_size: new_size})}

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
        {line, col} = Document.cursor(state.document)
        new_buf = Document.new(text)
        line_count = Document.line_count(new_buf)
        clamped_line = min(line, line_count - 1)

        clamped_col =
          case Document.lines(new_buf, clamped_line, 1) do
            [row] ->
              # col is a byte offset; clamp to last valid grapheme boundary
              Unicode.clamp_to_grapheme_boundary(row, min(col, byte_size(row)))

            _ ->
              0
          end

        new_buf = Document.move_to(new_buf, {clamped_line, clamped_col})
        first_line = text |> String.split("\n", parts: 2) |> List.first("")
        filetype = Filetype.detect_from_content(state.file_path, first_line)

        {new_mtime, new_size} = file_stat_info(state.file_path)

        new_state = %{
          state
          | document: new_buf,
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
    case write_file(file_path, Document.content(state.document)) do
      :ok ->
        {new_mtime, new_size} = file_stat_info(file_path)

        {:reply, :ok,
         mark_saved(%{state | file_path: file_path, mtime: new_mtime, file_size: new_size})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace_content, _new_content}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:replace_content, new_content}, _from, state) do
    new_state = push_undo_force(state, state.document)
    new_buf = Document.new(new_content)
    {:reply, :ok, mark_dirty(%{new_state | document: new_buf}) |> clear_edits()}
  end

  # Force replace bypasses read_only. Used by panel buffers (file tree, agent)
  # that are read-only to the user but need programmatic content updates.
  def handle_call({:replace_content_force, new_content}, _from, state) do
    new_buf = Document.new(new_content)
    {:reply, :ok, %{state | document: new_buf, version: state.version + 1, pending_edits: []}}
  end

  def handle_call(:content, _from, state) do
    {:reply, Document.content(state.document), state}
  end

  def handle_call({:byte_offset_for_line, line}, _from, state) do
    offset = Document.position_to_offset(state.document, {line, 0})
    {:reply, offset, state}
  end

  def handle_call({:get_lines, start, count}, _from, state) do
    {:reply, Document.lines(state.document, start, count), state}
  end

  def handle_call(:cursor, _from, state) do
    {:reply, Document.cursor(state.document), state}
  end

  def handle_call({:set_cursor, {line, col}}, _from, state) do
    doc = Document.move_to(state.document, {line, col})
    {:reply, :ok, %{state | document: doc}}
  end

  def handle_call({:move_cursor, direction}, _from, state) do
    doc = Document.move(state.document, direction)
    {:reply, :ok, %{state | document: doc}}
  end

  def handle_call(:line_count, _from, state) do
    {:reply, Document.line_count(state.document), state}
  end

  def handle_call(:dirty?, _from, state) do
    {:reply, state.dirty, state}
  end

  def handle_call(:flush_edits, _from, state) do
    edits = Enum.reverse(state.pending_edits)
    {:reply, edits, %{state | pending_edits: []}}
  end

  def handle_call(:version, _from, state) do
    {:reply, state.version, state}
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

  def handle_call(:buffer_type, _from, state) do
    {:reply, state.buffer_type, state}
  end

  # ── Buffer-local options handlers ──

  def handle_call({:get_option, name}, _from, state) do
    value = resolve_option(state, name)
    {:reply, value, state}
  end

  def handle_call({:set_option, name, value}, _from, state) do
    case Options.validate_option(name, value) do
      :ok ->
        new_state = %{state | options: Map.put(state.options, name, value)}
        {:reply, {:ok, value}, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:local_options, _from, state) do
    {:reply, state.options, state}
  end

  def handle_call({:append, text}, _from, state) do
    content = Document.content(state.document)
    new_content = content <> text
    new_buf = Document.new(new_content)
    # Move cursor to end
    line_count = Document.line_count(new_buf)
    last_line = max(0, line_count - 1)

    last_col =
      case Document.lines(new_buf, last_line, 1) do
        # last_grapheme_byte_offset returns 0 for empty rows, which is correct
        [row] -> Unicode.last_grapheme_byte_offset(row)
        _ -> 0
      end

    new_buf = Document.move_to(new_buf, {last_line, last_col})
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call({:render_snapshot, first_line, count}, _from, state) do
    buf = state.document

    # Use position_to_offset for O(1) byte offset lookup via line index,
    # instead of iterating all lines before first_line.
    first_line_byte_offset = Document.position_to_offset(buf, {first_line, 0})

    snapshot = %RenderSnapshot{
      cursor: Document.cursor(buf),
      line_count: Document.line_count(buf),
      lines: Document.lines(buf, first_line, count),
      file_path: state.file_path,
      filetype: state.filetype,
      buffer_type: state.buffer_type,
      dirty: state.dirty,
      name: state.name,
      read_only: state.read_only,
      first_line_byte_offset: first_line_byte_offset,
      version: state.version
    }

    {:reply, snapshot, state}
  end

  def handle_call({:content_range, from_pos, to_pos}, _from, state) do
    text = Document.content_range(state.document, from_pos, to_pos)
    {:reply, text, state}
  end

  def handle_call({:delete_range, _from_pos, _to_pos}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:delete_range, from_pos, to_pos}, _from, state) do
    old_doc = state.document
    new_buf = Document.delete_range(old_doc, from_pos, to_pos)

    if new_buf == old_doc do
      {:reply, :ok, state}
    else
      old_content = Document.content(old_doc)
      start_byte = byte_offset_at(old_content, from_pos)
      old_end_byte = byte_offset_at(old_content, to_pos)
      delta = EditDelta.deletion(start_byte, old_end_byte, from_pos, to_pos)
      {:reply, :ok, push_undo(state, new_buf) |> mark_dirty() |> record_edit(delta)}
    end
  end

  def handle_call({:get_range, start_pos, end_pos}, _from, state) do
    result = Document.get_range(state.document, start_pos, end_pos)
    {:reply, result, state}
  end

  def handle_call({:get_lines_content, start_line, end_line}, _from, state) do
    result = Document.get_lines_content(state.document, start_line, end_line)
    {:reply, result, state}
  end

  def handle_call({:delete_lines, _start_line, _end_line}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:delete_lines, start_line, end_line}, _from, state) do
    old_doc = state.document
    new_buf = Document.delete_lines(old_doc, start_line, end_line)

    if new_buf == old_doc do
      {:reply, :ok, state}
    else
      old_content = Document.content(old_doc)
      from_pos = {start_line, 0}
      # end_line is inclusive; delete through end of that line (including newline)
      to_pos = {end_line + 1, 0}
      start_byte = byte_offset_at(old_content, from_pos)
      old_end_byte = byte_offset_at(old_content, to_pos)
      delta = EditDelta.deletion(start_byte, old_end_byte, from_pos, to_pos)
      {:reply, :ok, push_undo(state, new_buf) |> mark_dirty() |> record_edit(delta)}
    end
  end

  def handle_call(:content_and_cursor, _from, state) do
    {:reply, Document.content_and_cursor(state.document), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.document, state}
  end

  def handle_call({:apply_snapshot, _new_buf}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:apply_snapshot, new_buf}, _from, state) do
    {:reply, :ok, push_undo(state, new_buf) |> mark_dirty() |> clear_edits()}
  end

  def handle_call({:clear_line, _line}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:clear_line, line}, _from, state) do
    {yanked, new_buf} = Document.clear_line(state.document, line)

    if new_buf == state.document do
      {:reply, {:ok, yanked}, state}
    else
      {:reply, {:ok, yanked}, push_undo(state, new_buf) |> mark_dirty()}
    end
  end

  def handle_call(:undo, _from, state) do
    case state.undo_stack do
      [] ->
        {:reply, :ok, state}

      [{prev_version, prev_buf} | rest_undo] ->
        redo_entry = {state.version, state.document}

        new_state =
          %{
            state
            | document: prev_buf,
              version: prev_version,
              undo_stack: rest_undo,
              redo_stack: [redo_entry | state.redo_stack]
          }
          |> sync_dirty()
          |> clear_edits()

        {:reply, :ok, new_state}
    end
  end

  def handle_call(:redo, _from, state) do
    case state.redo_stack do
      [] ->
        {:reply, :ok, state}

      [{next_version, next_buf} | rest_redo] ->
        undo_entry = {state.version, state.document}

        new_state =
          %{
            state
            | document: next_buf,
              version: next_version,
              redo_stack: rest_redo,
              undo_stack: [undo_entry | state.undo_stack]
          }
          |> sync_dirty()
          |> clear_edits()

        {:reply, :ok, new_state}
    end
  end

  def handle_call(:break_undo_coalescing, _from, state) do
    {:reply, :ok, BufState.break_undo_coalescing(state)}
  end

  # ── Decoration callbacks ──

  def handle_call({:add_highlight, start_pos, end_pos, opts}, _from, state) do
    {id, decs} = Decorations.add_highlight(state.decorations, start_pos, end_pos, opts)
    {:reply, id, %{state | decorations: decs}}
  end

  def handle_call({:remove_highlight, id}, _from, state) do
    decs = Decorations.remove_highlight(state.decorations, id)
    {:reply, :ok, %{state | decorations: decs}}
  end

  def handle_call({:remove_highlight_group, group}, _from, state) do
    decs = Decorations.remove_group(state.decorations, group)
    {:reply, :ok, %{state | decorations: decs}}
  end

  def handle_call({:batch_decorations, fun}, _from, state) do
    decs = Decorations.batch(state.decorations, fun)
    {:reply, :ok, %{state | decorations: decs}}
  end

  def handle_call({:add_virtual_text, anchor, opts}, _from, state) do
    {id, decs} = Decorations.add_virtual_text(state.decorations, anchor, opts)
    {:reply, id, %{state | decorations: decs}}
  end

  def handle_call({:remove_virtual_text, id}, _from, state) do
    decs = Decorations.remove_virtual_text(state.decorations, id)
    {:reply, :ok, %{state | decorations: decs}}
  end

  def handle_call(:decorations, _from, state) do
    {:reply, state.decorations, state}
  end

  def handle_call(:decorations_version, _from, state) do
    {:reply, state.decorations.version, state}
  end

  # ── Private ──

  # Resolves an option using the chain: buffer-local → filetype → global.
  # With eager seeding, the buffer-local map already contains filetype/global
  # defaults, so the fallback path is rarely hit (only for options not in
  # the seed list, or if the Options agent was unavailable at init time).
  @spec resolve_option(BufState.t(), atom()) :: term()
  defp resolve_option(%{options: opts, filetype: ft}, name) do
    case Map.fetch(opts, name) do
      {:ok, value} -> value
      :error -> Options.get_for_filetype(name, ft)
    end
  end

  # Buffer-local option names that get pre-populated from filetype/global
  # defaults at buffer creation time. This avoids cross-process calls to
  # the global Options agent on every keystroke or render frame.
  @buffer_local_options [
    :tab_width,
    :indent_with,
    :wrap,
    :linebreak,
    :breakindent,
    :scroll_margin,
    :autopair,
    :clipboard,
    :trim_trailing_whitespace,
    :insert_final_newline,
    :format_on_save,
    :formatter,
    :line_numbers
  ]

  @spec seed_options(atom()) :: %{atom() => term()}
  defp seed_options(filetype) do
    Map.new(@buffer_local_options, fn name ->
      {name, Options.get_for_filetype(name, filetype)}
    end)
  catch
    :exit, _ -> %{}
  end

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

  # Delegates to BufState for time-based undo coalescing.
  @spec push_undo(state(), Document.t()) :: state()
  defp push_undo(state, new_buf), do: BufState.push_undo(state, new_buf)

  # Force-pushes an undo entry, bypassing coalescing. Used for explicit
  # user actions like :replace_content.
  @spec push_undo_force(state(), Document.t()) :: state()
  defp push_undo_force(state, new_buf), do: BufState.push_undo_force(state, new_buf)

  @spec mark_dirty(state()) :: state()
  defp mark_dirty(state), do: BufState.mark_dirty(state)

  @spec sync_dirty(state()) :: state()
  defp sync_dirty(state), do: BufState.sync_dirty(state)

  @spec mark_saved(state()) :: state()
  defp mark_saved(state), do: BufState.mark_saved(state)

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

  # ── Edit delta tracking ──

  @spec record_edit(state(), EditDelta.t()) :: state()
  defp record_edit(state, delta) do
    state = %{state | pending_edits: [delta | state.pending_edits]}

    # Adjust decoration anchors based on the edit
    if Decorations.empty?(state.decorations) do
      state
    else
      adjusted =
        Decorations.adjust_for_edit(
          state.decorations,
          delta.start_position,
          delta.old_end_position,
          delta.new_end_position
        )

      %{state | decorations: adjusted}
    end
  end

  # Clear pending edits to force HighlightSync into full content sync.
  # Used for operations where computing accurate deltas is impractical
  # (undo, redo, multi-edit batches, full content replacement).
  @spec clear_edits(state()) :: state()
  defp clear_edits(state), do: %{state | pending_edits: []}

  # Compute byte offset for a {line, col} position in content.
  @spec byte_offset_at(String.t(), {non_neg_integer(), non_neg_integer()}) :: non_neg_integer()
  defp byte_offset_at(content, {target_line, target_col}) do
    lines = String.split(content, "\n")

    bytes_before_line =
      lines
      |> Enum.take(target_line)
      |> Enum.reduce(0, fn line, acc -> acc + byte_size(line) + 1 end)

    line_text = Enum.at(lines, target_line, "")

    col_bytes =
      line_text
      |> String.graphemes()
      |> Enum.take(target_col)
      |> IO.iodata_to_binary()
      |> byte_size()

    bytes_before_line + col_bytes
  end

  @spec advance_position({non_neg_integer(), non_neg_integer()}, String.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp advance_position({line, col}, text) do
    text
    |> String.split("\n")
    |> case do
      [single] ->
        {line, col + String.length(single)}

      parts ->
        new_lines = length(parts) - 1
        last_part = List.last(parts)
        {line + new_lines, String.length(last_part)}
    end
  end
end
