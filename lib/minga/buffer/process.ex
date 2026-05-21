defmodule Minga.Buffer.Process do
  @moduledoc """
  GenServer wrapping a `Document` with file I/O and dirty tracking.

  Each open file gets its own `Buffer.Process` process, managed by
  the `Buffer.Supervisor` (DynamicSupervisor). If a buffer process
  crashes, only that buffer is lost, and all other buffers and the
  editor continue running.

  ## Examples

      {:ok, pid} = Minga.Buffer.Process.start_link(file_path: "README.md")
      :ok = Minga.Buffer.Process.insert_char(pid, "x")
      true = Minga.Buffer.Process.dirty?(pid)
      :ok = Minga.Buffer.Process.save(pid)
      false = Minga.Buffer.Process.dirty?(pid)
  """

  use GenServer

  alias Minga.Buffer.{
    ChangeLog,
    Cursor,
    Document,
    Lines,
    Operation,
    Persistence,
    Position,
    Replace,
    UndoHistory,
    UndoPatch
  }

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.EditSource
  alias Minga.Config
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias Minga.Editing.NavigableContent.BufferSnapshot
  alias Minga.Editing.Scroll
  alias Minga.Events
  alias Minga.Language

  alias Minga.Buffer.State, as: BufState

  @typedoc "Options for starting a buffer server."
  @type start_opt ::
          {:file_path, String.t()}
          | {:content, String.t()}
          | {:name, GenServer.name()}
          | {:buffer_name, String.t()}
          | {:buffer_type, BufState.buffer_type()}
          | {:storage, BufState.storage()}
          | {:filetype, atom()}
          | {:options_server, Minga.Config.Options.server() | nil}
          | {:read_only, boolean()}
          | {:unlisted, boolean()}
          | {:persistent, boolean()}
          | {:events_registry, Minga.Events.registry()}

  @typedoc "Internal state of the buffer server."
  @type state :: BufState.t()
  @type edit_delta_update :: {:ok, [EditDelta.t()]} | :reset_required

  # ── Child Spec ──

  @doc """
  Returns a child spec with `restart: :temporary`.

  Buffers run under a DynamicSupervisor. If a buffer crashes, it should
  stay dead rather than restarting without its original init args (file
  path, content). The Editor detects the dead buffer via `:DOWN` monitor
  and shows a clear indicator to the user.
  """
  @spec child_spec([start_opt()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

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
  def open(server, file_path) do
    GenServer.call(server, {:open, file_path})
  end

  @doc "Inserts a character at the current cursor position."
  @spec insert_char(GenServer.server(), String.t(), EditSource.t()) :: :ok
  def insert_char(server, char, source \\ EditSource.user()) do
    GenServer.call(server, {:insert_text, char, source})
  end

  @doc """
  Inserts a string at the current cursor position.

  Each character is inserted sequentially, advancing the cursor.
  """
  @spec insert_text(GenServer.server(), String.t(), EditSource.t()) :: :ok
  def insert_text(server, text, source \\ EditSource.user()) do
    GenServer.call(server, {:insert_text, text, source})
  end

  @doc """
  Replaces a range of text with new text.

  Moves to the start of the range, deletes the range, then inserts the
  new text. Used by LSP text edits.
  """
  @spec apply_edit(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          EditSource.t()
        ) :: :ok
  def apply_edit(
        server,
        start_line,
        start_col,
        end_line,
        end_col,
        new_text,
        source \\ EditSource.user()
      ) do
    GenServer.call(
      server,
      {:apply_edit, {start_line, start_col}, {end_line, end_col}, new_text, source}
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

  Source defaults to `{:lsp, :unknown}` (not `:user`) because batch edits
  are typically LSP code actions or agent tool calls, not interactive typing.
  """
  @spec apply_edits(GenServer.server(), [text_edit()], EditSource.t()) :: :ok
  def apply_edits(server, edits, source \\ EditSource.lsp(:unknown)) when is_list(edits) do
    GenServer.call(server, {:apply_edits, edits, source})
  end

  @doc """
  Atomically finds and replaces text in the buffer.

  The search, ambiguity check, and replacement all happen inside a single
  `handle_call`, so there is no TOCTOU race between reading content and
  applying the edit. Returns `{:ok, message}` on success, or `{:error, reason}`
  if the text is not found, is ambiguous (multiple matches), or the buffer
  is read-only.
  """
  @typedoc "An edit boundary as `{start_line, end_line}` (both inclusive, 0-indexed), or nil for unbounded."
  @type boundary :: {non_neg_integer(), non_neg_integer()} | nil

  @spec find_and_replace(GenServer.server(), String.t(), String.t(), boundary()) ::
          {:ok, String.t()} | {:error, String.t()}
  def find_and_replace(server, old_text, new_text, boundary \\ nil) do
    GenServer.call(server, {:find_and_replace, old_text, new_text, boundary})
  end

  @typedoc "A find-and-replace edit pair for batch operations."
  @type replace_edit :: {old_text :: String.t(), new_text :: String.t()}

  @typedoc "Result of a single edit within a batch."
  @type replace_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Atomically applies multiple find-and-replace edits in a single `handle_call`.

  Edits are applied sequentially: earlier edits affect the content that later
  edits search against. Failed edits (not found, ambiguous) are reported but
  don't block subsequent edits. A single undo entry is pushed for the entire
  batch.

  When `boundary` is provided, each edit is checked against the boundary and
  rejected if the match falls outside the allowed line range.

  Returns `{:ok, results}` where results is a list of per-edit outcomes.
  """
  @spec find_and_replace_batch(GenServer.server(), [replace_edit()], boundary()) ::
          {:ok, [replace_result()]} | {:error, String.t()}
  def find_and_replace_batch(server, edits, boundary \\ nil) when is_list(edits) do
    GenServer.call(server, {:find_and_replace_batch, edits, boundary})
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
  def move_to(server, {line, col} = pos) when line >= 0 and col >= 0 do
    GenServer.call(server, {:move_to, pos})
  end

  @file_io_call_timeout 30_000

  @doc "Saves the buffer content to the associated file."
  @spec save(GenServer.server()) :: :ok | {:error, term()}
  def save(server) do
    GenServer.call(server, :save, @file_io_call_timeout)
  end

  @doc "Force-saves the buffer, skipping mtime conflict detection."
  @spec force_save(GenServer.server()) :: :ok | {:error, term()}
  def force_save(server) do
    GenServer.call(server, :force_save, @file_io_call_timeout)
  end

  @doc "Reloads the buffer from disk, preserving cursor position (clamped). Clears undo/redo history."
  @spec reload(GenServer.server()) :: :ok | {:error, term()}
  def reload(server) do
    GenServer.call(server, :reload, @file_io_call_timeout)
  end

  @doc "Saves the buffer content to a specific file path."
  @spec save_as(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def save_as(server, file_path) do
    GenServer.call(server, {:save_as, file_path}, @file_io_call_timeout)
  end

  @doc "Retargets the buffer to a new file path without writing content."
  @spec retarget_path(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def retarget_path(server, file_path) do
    GenServer.call(server, {:retarget_path, file_path}, @file_io_call_timeout)
  end

  @doc "Replaces the entire buffer content, pushing the old content onto the undo stack."
  @spec replace_content(GenServer.server(), String.t(), BufState.edit_source()) ::
          :ok | {:error, :read_only}
  def replace_content(server, new_content, source \\ :user)
      when is_binary(new_content) and source in [:user, :agent, :lsp, :recovery] do
    GenServer.call(server, {:replace_content, new_content, source})
  end

  @doc "Replaces buffer content bypassing read-only. For programmatic panel updates."
  @spec replace_generated_content(GenServer.server(), String.t()) :: :ok
  def replace_generated_content(server, new_content) do
    GenServer.call(server, {:replace_generated_content, new_content})
  end

  @doc "Accepts content as the saved base revision and clears dirty state."
  @spec accept_saved_content(GenServer.server(), String.t()) :: :ok
  def accept_saved_content(server, new_content) do
    GenServer.call(server, {:accept_saved_content, new_content}, @file_io_call_timeout)
  end

  @doc "Acknowledges the current disk metadata after the user chooses to keep local edits."
  @spec acknowledge_disk_change(GenServer.server()) :: :ok
  def acknowledge_disk_change(server) do
    GenServer.call(server, :acknowledge_disk_change, @file_io_call_timeout)
  end

  @doc "Returns the full text content of the buffer."
  @spec content(GenServer.server()) :: String.t()
  def content(server) do
    GenServer.call(server, :content)
  end

  @doc "Returns the byte offset for the start of a given line."
  @spec byte_offset_for_line(GenServer.server(), non_neg_integer()) :: non_neg_integer()
  def byte_offset_for_line(server, line) when line >= 0 do
    GenServer.call(server, {:byte_offset_for_line, line})
  end

  @doc "Returns a range of lines from the buffer."
  @spec lines(GenServer.server(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  def lines(server, start, count) when start >= 0 and count >= 0 do
    GenServer.call(server, {:lines, start, count})
  end

  @doc "Returns the current cursor position."
  @spec cursor(GenServer.server()) :: Document.position()
  def cursor(server) do
    GenServer.call(server, :cursor)
  end

  @doc """
  Moves the cursor left or right if the move is valid, performing the boundary
  check inside the buffer process. Returns `{:ok, new_position}` if the cursor
  moved, or `:at_boundary` if the cursor was already at the boundary.

  For `:left`, the boundary is column 0.
  For `:right`, the boundary is the last grapheme position on the current line.

  This avoids copying the entire `Document.t()` across the process boundary
  just to check whether the cursor is at a line boundary.
  """
  @spec move_if_possible(GenServer.server(), :left | :right) ::
          {:ok, Document.position()} | :at_boundary
  def move_if_possible(server, direction) when direction in [:left, :right] do
    GenServer.call(server, {:move_if_possible, direction})
  end

  @doc "Returns the total line count."
  @spec line_count(GenServer.server()) :: pos_integer()
  def line_count(server), do: GenServer.call(server, :line_count)

  @doc "Returns whether the buffer has unsaved changes."
  @spec dirty?(GenServer.server()) :: boolean()
  def dirty?(server), do: GenServer.call(server, :dirty?)

  @doc "Returns the buffer's mutation version counter (increments on every content change)."
  @spec version(GenServer.server()) :: non_neg_integer()
  def version(server), do: GenServer.call(server, :version)

  @doc """
  Returns and clears pending edit deltas accumulated since the last legacy consumer read.

  Deprecated: use `consume_edit_deltas/2` with a consumer_id for per-consumer cursors.
  This legacy version destructively drains the shared pending changes list.
  """
  @deprecated "Use consume_edit_deltas/2 with a consumer_id instead"
  @spec consume_edit_deltas(GenServer.server()) :: [EditDelta.t()]
  def consume_edit_deltas(server), do: GenServer.call(server, :consume_edit_deltas)

  @doc """
  Returns edit deltas accumulated since the given consumer's last read.

  Each consumer is identified by an atom (e.g., `:lsp`, `:highlight`).
  The buffer tracks a per-consumer cursor (sequence number). On each call,
  deltas since that cursor are returned and the cursor advances. The buffer
  trims deltas that all registered consumers have read. Returns `:reset_required`
  if older retained deltas were compacted before the consumer caught up.

  This avoids the data race where two consumers calling `consume_edit_deltas/1`
  would each miss the other's deltas.

  Deprecated: prefer consuming deltas from `BufferChangedEvent` payloads
  on the event bus. LSP SyncServer already accumulates deltas from events.
  HighlightSync still uses this during the migration period since it runs
  synchronously inside the Editor GenServer before the deferred broadcast fires.
  """
  @spec consume_edit_deltas(GenServer.server(), atom()) :: edit_delta_update()
  def consume_edit_deltas(server, consumer_id) do
    GenServer.call(server, {:consume_edit_deltas, consumer_id})
  end

  @doc """
  Looks up the buffer pid for a file path via `Minga.Buffer.Registry`.

  Returns `{:ok, pid}` if a buffer is registered for the given path,
  or `:not_found` if no buffer has that path open. O(1) ETS lookup,
  no GenServer calls. The path is expanded to an absolute path before lookup.
  """
  @spec pid_for_path(String.t()) :: {:ok, pid()} | :not_found
  def pid_for_path(path) do
    abs_path = Path.expand(path)

    case Registry.lookup(Minga.Buffer.Registry, abs_path) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :not_found
    end
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

  @doc """
  Returns the buffer-local face overrides map.

  Face overrides are `%{face_name => [attr: value, ...]}` pairs that
  are merged on top of the theme's face registry when rendering this
  buffer. Used for filetype-specific styling (e.g., Markdown uses a
  different default font) and buffer-local customization.
  """
  @spec face_overrides(GenServer.server()) :: %{String.t() => keyword()}
  def face_overrides(server) do
    GenServer.call(server, :face_overrides)
  end

  @doc """
  Sets a buffer-local face override.

  Merges the given attributes on top of the named face for this buffer
  only. Other buffers are unaffected. The override persists until
  cleared with `clear_face_override/2`.

  ## Examples

      Buffer.Process.remap_face(buf, "default", fg: 0x000000, bg: 0xFFFFFF)
      Buffer.Process.remap_face(buf, "comment", italic: false)
  """
  @spec remap_face(GenServer.server(), String.t(), keyword()) :: :ok
  def remap_face(server, face_name, attrs) when is_list(attrs) do
    GenServer.call(server, {:remap_face, face_name, attrs})
  end

  @doc """
  Clears a buffer-local face override, restoring the theme default.
  """
  @spec clear_face_override(GenServer.server(), String.t()) :: :ok
  def clear_face_override(server, face_name) do
    GenServer.call(server, {:clear_face_override, face_name})
  end

  @doc """
  Changes the buffer's filetype and re-seeds per-filetype options.

  The buffer content is not modified; only metadata (filetype, tab_width,
  indent_with, etc.) changes. The caller is responsible for triggering
  a highlight reparse after this call.
  """
  @spec set_filetype(GenServer.server(), atom()) :: :ok
  def set_filetype(server, filetype) do
    GenServer.call(server, {:set_filetype, filetype})
  end

  @doc "Returns the buffer name (e.g. `*Messages*`), or `nil` for file buffers."
  @spec buffer_name(GenServer.server()) :: String.t() | nil
  def buffer_name(server), do: GenServer.call(server, :buffer_name)

  @doc """
  Returns the display name for use in the status bar and modeline.

  For named buffers (e.g. `*Messages*`), returns the name directly with a
  `[RO]` suffix when read-only. For file buffers, returns `Path.basename(file_path)`
  with a `[RO]` suffix when read-only, or `"[no file]"` when no path is set.

  Single GenServer round-trip; prefer over combining `buffer_name/1`,
  `file_path/1`, and `read_only?/1` separately.
  """
  @spec display_name(GenServer.server()) :: String.t()
  def display_name(server) do
    GenServer.call(server, :display_name)
  end

  @doc "Returns whether the buffer is read-only."
  @spec read_only?(GenServer.server()) :: boolean()
  def read_only?(server) do
    GenServer.call(server, :read_only?)
  end

  @doc "Returns the buffer storage backend."
  @spec storage(GenServer.server()) :: BufState.storage()
  def storage(server) do
    GenServer.call(server, :storage)
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
  def set_option(server, name, value) do
    GenServer.call(server, {:set_option, name, value})
  end

  @doc """
  Returns all buffer option values currently cached on this buffer.
  """
  @spec local_options(GenServer.server()) :: %{atom() => term()}
  def local_options(server) do
    GenServer.call(server, :local_options)
  end

  @doc """
  Returns only options explicitly overridden on this buffer.
  """
  @spec local_option_overrides(GenServer.server()) :: %{atom() => term()}
  def local_option_overrides(server) do
    GenServer.call(server, :local_option_overrides)
  end

  @doc "Appends text to the end of the buffer, bypassing read-only. For programmatic writes."
  @spec append(GenServer.server(), String.t()) :: :ok
  def append(server, text) do
    GenServer.call(server, {:append, text})
  end

  alias Minga.Buffer.RenderSnapshot

  @doc """
  Returns all data needed to render a single frame in one GenServer call.

  Fetches cursor position, total line count, the visible line range starting at
  `first_line` (up to `count` lines), file path, and dirty flag atomically.
  This replaces 5 individual calls (cursor, line_count, lines, file_path,
  dirty?) with a single round-trip.
  """
  @spec render_snapshot(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          RenderSnapshot.t()
  def render_snapshot(server, first_line, count) when first_line >= 0 and count >= 0 do
    GenServer.call(server, {:render_snapshot, first_line, count})
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
  @spec text_between_inclusive(GenServer.server(), Document.position(), Document.position()) ::
          String.t()
  def text_between_inclusive(server, start_pos, end_pos) do
    GenServer.call(server, {:text_between_inclusive, start_pos, end_pos})
  end

  @doc """
  Returns the grapheme count in the range [start_pos, end_pos] inclusive.
  Positions are sorted automatically.
  """
  @spec content_range_length(GenServer.server(), Document.position(), Document.position()) ::
          non_neg_integer()
  def content_range_length(server, start_pos, end_pos) do
    GenServer.call(server, {:content_range_length, start_pos, end_pos})
  end

  @doc """
  Returns the joined text of lines [start_line, end_line] inclusive (no trailing newline).
  """
  @spec content_on_lines(GenServer.server(), non_neg_integer(), non_neg_integer()) :: String.t()
  def content_on_lines(server, start_line, end_line)
      when start_line >= 0 and end_line >= 0 do
    GenServer.call(server, {:content_on_lines, start_line, end_line})
  end

  @doc "Returns the content and cursor position in a single GenServer call."
  @spec content_and_cursor(GenServer.server()) :: {String.t(), Document.position()}
  def content_and_cursor(server) do
    GenServer.call(server, :content_and_cursor)
  end

  @doc "Clears all content on the given line. Returns `{:ok, yanked_text}`."
  @spec clear_line(GenServer.server(), non_neg_integer()) :: {:ok, String.t()}
  def clear_line(server, line) when line >= 0 do
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

  @doc "Returns the edit source of the most recent undo entry, or `nil` if the undo stack is empty."
  @spec last_undo_source(GenServer.server()) :: Minga.Buffer.State.edit_source() | nil
  def last_undo_source(server) do
    GenServer.call(server, :last_undo_source)
  end

  @doc "Returns the edit source of the most recent redo entry, or `nil` if the redo stack is empty."
  @spec last_redo_source(GenServer.server()) :: Minga.Buffer.State.edit_source() | nil
  def last_redo_source(server) do
    GenServer.call(server, :last_redo_source)
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
  def delete_lines(server, start_line, end_line) when start_line >= 0 and end_line >= 0 do
    GenServer.call(server, {:delete_lines, start_line, end_line})
  end

  @doc """
  Returns the underlying `Document.t()` struct for pure computation.

  Use this to batch multiple reads into a single GenServer call. Perform
  all calculations on the returned struct, then apply the result with
  `move_to/2` (cursor-only changes) or `commit_snapshot/2` (content changes).
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
  @spec commit_snapshot(GenServer.server(), Document.t()) :: :ok
  def commit_snapshot(server, %Document{} = new_buf) do
    GenServer.call(server, {:commit_snapshot, new_buf})
  end

  @doc """
  Takes a snapshot wrapped in a `BufferSnapshot` struct for use with the
  `NavigableContent` protocol. Includes the given scroll state so that
  scroll operations can be composed with cursor and content changes.

  After operating on the snapshot through `NavigableContent`, apply the
  result back with `commit_navigable_snapshot/2`.
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
  @spec commit_navigable_snapshot(GenServer.server(), BufferSnapshot.t()) :: Scroll.t()
  def commit_navigable_snapshot(server, %BufferSnapshot{document: new_doc, scroll: scroll}) do
    commit_snapshot(server, new_doc)
    scroll
  end

  # ── Decoration API ──

  @doc """
  Adds a highlight range decoration to the buffer.

  Returns the decoration ID (a reference) for later removal.
  See `Minga.Core.Decorations.add_highlight/4` for options.
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
  def remove_highlight_group(server, group) do
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
  Atomically replaces buffer content and rebuilds decorations in a single GenServer call.

  The `decoration_fn` receives a fresh `Decorations.new()` and returns
  the new decorations. Optional `cursor` clamps the cursor position.
  This prevents a render frame from seeing new content with zero decorations.
  """
  @spec replace_content_with_decorations(
          GenServer.server(),
          String.t(),
          (Decorations.t() -> Decorations.t()),
          keyword()
        ) :: :ok
  def replace_content_with_decorations(server, content, decoration_fn, opts \\ [])
      when is_function(decoration_fn, 1) do
    GenServer.call(server, {:replace_content_with_decorations, content, decoration_fn, opts})
  end

  @doc """
  Adds a virtual text decoration to the buffer.

  Returns the decoration ID (a reference) for later removal.
  See `Minga.Core.Decorations.add_virtual_text/3` for options.
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

  @doc """
  Adds a block decoration to the buffer.

  Returns the decoration ID for later removal.
  See `Minga.Core.Decorations.add_block_decoration/3` for options.
  """
  @spec add_block_decoration(GenServer.server(), non_neg_integer(), keyword()) :: reference()
  def add_block_decoration(server, anchor_line, opts) do
    GenServer.call(server, {:add_block_decoration, anchor_line, opts})
  end

  @doc "Removes a block decoration by ID."
  @spec remove_block_decoration(GenServer.server(), reference()) :: :ok
  def remove_block_decoration(server, id) do
    GenServer.call(server, {:remove_block_decoration, id})
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
    storage = Keyword.get(opts, :storage, :local)

    case Persistence.load_content(storage, file_path, initial_content) do
      {:ok, text, path, {mtime, size}} ->
        filetype =
          case Keyword.get(opts, :filetype) do
            nil ->
              first_line = text |> String.split("\n", parts: 2) |> List.first("")
              Language.detect_filetype_from_content(path, first_line)

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

        options_server = normalize_options_server(Keyword.get(opts, :options_server))

        state = %BufState{
          document: Document.new(text),
          file_path: path,
          filetype: filetype,
          options_server: options_server,
          storage: storage,
          buffer_type: buffer_type,
          save_state: BufState.loaded_save_state(path, {mtime, size}, text),
          name: Keyword.get(opts, :buffer_name),
          read_only: read_only,
          unlisted: Keyword.get(opts, :unlisted, false),
          persistent: Keyword.get(opts, :persistent, false),
          options: seed_options(options_server, filetype),
          explicit_options: MapSet.new(),
          swap_dir: Keyword.get(opts, :swap_dir),
          events_registry: Keyword.get(opts, :events_registry, Minga.Events.default_registry())
        }

        register_path(path)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:open, file_path}, _from, state) do
    case Persistence.read_content(state, file_path) do
      {:ok, text} ->
        first_line = text |> String.split("\n", parts: 2) |> List.first("")
        filetype = Language.detect_filetype_from_content(file_path, first_line)

        {mtime, size} = Persistence.file_metadata(state, file_path)

        new_state = %{
          BufState.load_saved_content(state, file_path, {mtime, size}, text)
          | document: Document.new(text),
            file_path: file_path,
            filetype: filetype,
            options: reseed_options(state, filetype),
            decorations: Decorations.new(),
            undo_history: UndoHistory.clear(state.undo_history)
        }

        unregister_path(state.file_path)
        register_path(file_path)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:insert_text, _text, _source}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:insert_text, text, source}, _from, state) do
    {:edited, new_doc, delta} = Operation.insert_at_cursor(state.document, text)
    undo_source = EditSource.to_undo_source(source)

    state =
      push_undo(state, new_doc, undo_source, delta) |> mark_dirty() |> record_edit(delta, source)

    {:reply, :ok, state}
  end

  def handle_call(
        {:apply_edit, _from_pos, _to_pos, _text, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:apply_edit, from_pos, to_pos, new_text, source}, _from, state) do
    {:edited, new_doc, delta} =
      Operation.replace_range(state.document, from_pos, to_pos, new_text)

    undo_source = EditSource.to_undo_source(source)

    {:reply, :ok,
     push_undo(state, new_doc, undo_source, delta) |> mark_dirty() |> record_edit(delta, source)}
  end

  def handle_call({:apply_edits, _edits, _source}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:apply_edits, [], _source}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:apply_edits, edits, source}, _from, state) do
    {doc, patches} = Operation.replace_ranges_with_patches(state.document, edits)
    undo_source = EditSource.to_undo_source(source)

    # Batch edits shift offsets between replacements, so consumers need a full content sync.
    {:reply, :ok,
     push_undo_batch(state, doc, undo_source, patches) |> mark_dirty() |> clear_edits(source)}
  end

  # ── Find and Replace ──

  def handle_call({:find_and_replace, _old, _new, _boundary}, _from, %{read_only: true} = state) do
    {:reply, {:error, "buffer is read-only"}, state}
  end

  def handle_call({:find_and_replace, old_text, new_text, boundary}, _from, state) do
    case Replace.apply(state.document, old_text, new_text, boundary) do
      {:ok, new_doc, msg} ->
        {:reply, {:ok, msg},
         push_undo_force_full(state, new_doc, :agent)
         |> mark_dirty()
         |> clear_edits(EditSource.agent(self(), "unknown"))}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:find_and_replace_batch, _edits, _boundary}, _from, %{read_only: true} = state) do
    {:reply, {:error, "buffer is read-only"}, state}
  end

  def handle_call({:find_and_replace_batch, [], _boundary}, _from, state) do
    {:reply, {:ok, []}, state}
  end

  def handle_call({:find_and_replace_batch, edits, boundary}, _from, state) do
    {final_doc, results, any_applied?} = Replace.apply_batch(state.document, edits, boundary)

    new_state =
      if any_applied? do
        push_undo_force_full(state, final_doc, :agent)
        |> mark_dirty()
        |> clear_edits(EditSource.agent(self(), "unknown"))
      else
        state
      end

    {:reply, {:ok, results}, new_state}
  end

  def handle_call(:delete_before, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(:delete_before, _from, state) do
    case Operation.backspace(state.document) do
      :unchanged ->
        {:reply, :ok, state}

      {:edited, new_doc, delta} ->
        {:reply, :ok,
         push_undo(state, new_doc, :user, delta) |> mark_dirty() |> record_edit(delta)}
    end
  end

  def handle_call(:delete_at, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(:delete_at, _from, state) do
    case Operation.delete_forward(state.document) do
      :unchanged ->
        {:reply, :ok, state}

      {:edited, new_doc, delta} ->
        {:reply, :ok,
         push_undo(state, new_doc, :user, delta) |> mark_dirty() |> record_edit(delta)}
    end
  end

  def handle_call({:move, direction}, _from, state) do
    new_buf = Cursor.move(state.document, direction)
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call({:move_to, pos}, _from, state) do
    new_buf = Cursor.place(state.document, pos)
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call(:save, _from, %{buffer_type: bt} = state) when bt in [:nofile, :nowrite] do
    {:reply, {:error, :buffer_not_saveable}, state}
  end

  def handle_call(:save, _from, %{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  def handle_call(:save, _from, state) do
    {disk_mtime, disk_size} = Persistence.file_metadata(state, state.file_path)

    if Persistence.changed_since_saved?(state, disk_mtime, disk_size) do
      {:reply, {:error, :file_changed}, state}
    else
      content = Document.content(state.document)

      case Persistence.write_content(state, state.file_path, content) do
        :ok ->
          {new_mtime, new_size} = Persistence.file_metadata(state, state.file_path)

          {:reply, :ok, mark_saved(state, {new_mtime, new_size}, content)}

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
    content = Document.content(state.document)

    case Persistence.write_content(state, state.file_path, content) do
      :ok ->
        {new_mtime, new_size} = Persistence.file_metadata(state, state.file_path)

        {:reply, :ok, mark_saved(state, {new_mtime, new_size}, content)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reload, _from, %{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  def handle_call(:reload, _from, state) do
    case Persistence.read_content(state, state.file_path) do
      {:ok, text} ->
        {line, col} = Document.cursor(state.document)
        new_buf = Document.new(text)
        line_count = Document.line_count(new_buf)
        clamped_line = min(line, line_count - 1)

        clamped_col =
          case Lines.slice(new_buf, clamped_line, 1) do
            [row] ->
              # col is a byte offset; clamp to last valid grapheme boundary
              Unicode.clamp_to_grapheme_boundary(row, min(col, byte_size(row)))

            _ ->
              0
          end

        new_buf = Cursor.place(new_buf, {clamped_line, clamped_col})
        first_line = text |> String.split("\n", parts: 2) |> List.first("")
        filetype = Language.detect_filetype_from_content(state.file_path, first_line)

        {new_mtime, new_size} = Persistence.file_metadata(state, state.file_path)

        new_state = %{
          BufState.load_saved_content(state, state.file_path, {new_mtime, new_size}, text)
          | document: new_buf,
            filetype: filetype,
            options: reseed_options(state, filetype),
            undo_history: UndoHistory.clear(state.undo_history),
            decorations: Decorations.new()
        }

        defer_content_replaced(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:save_as, file_path}, _from, state) do
    content = Document.content(state.document)

    case Persistence.write_content(state, file_path, content) do
      :ok ->
        {new_mtime, new_size} = Persistence.file_metadata(state, file_path)
        unregister_path(state.file_path)
        register_path(file_path)

        new_state = BufState.retarget_path(state, file_path)
        {:reply, :ok, mark_saved(new_state, {new_mtime, new_size}, content)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:retarget_path, _file_path}, _from, %{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  def handle_call({:retarget_path, file_path}, _from, state) do
    new_path = Path.expand(file_path)
    old_path = state.file_path && Path.expand(state.file_path)

    if old_path == new_path do
      {:reply, :ok, state}
    else
      unregister_path(state.file_path)
      register_path(new_path)
      {:reply, :ok, BufState.retarget_path(state, new_path)}
    end
  end

  def handle_call({:replace_content, _new_content, _source}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:replace_content, new_content, source}, _from, state) do
    new_buf = Document.new(new_content)
    new_state = push_undo_force_full(state, new_buf, source)
    event_source = EditSource.from_undo_source(source)
    {:reply, :ok, mark_dirty(new_state) |> clear_edits(event_source)}
  end

  # Force replace bypasses read_only. Used by panel buffers (file tree, agent)
  # that are read-only to the user but need programmatic content updates.
  def handle_call({:replace_generated_content, new_content}, _from, state) do
    new_buf = Document.new(new_content)

    new_state = %{
      BufState.record_clean_change(state)
      | document: new_buf,
        undo_history: UndoHistory.clear(state.undo_history),
        change_log: ChangeLog.clear(state.change_log),
        decorations: Decorations.new()
    }

    defer_content_replaced(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:accept_saved_content, new_content}, _from, state) do
    new_buf = Document.new(new_content)
    {mtime, size} = Persistence.file_metadata(state, state.file_path)

    new_state = %{
      BufState.accept_saved_content(state, {mtime, size}, new_content)
      | document: new_buf,
        undo_history: UndoHistory.clear(state.undo_history),
        change_log: ChangeLog.clear(state.change_log),
        decorations: Decorations.new()
    }

    defer_content_replaced(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:acknowledge_disk_change, _from, %{file_path: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:acknowledge_disk_change, _from, state) do
    case Persistence.file_info(state, state.file_path) do
      {:ok, %{mtime: mtime, size: size}} ->
        {:reply, :ok, BufState.acknowledge_disk_metadata(state, {mtime, size})}

      {:error, _reason} ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:content, _from, state) do
    {:reply, Document.content(state.document), state}
  end

  def handle_call({:byte_offset_for_line, line}, _from, state) do
    offset = Position.point_for(state.document, {line, 0})
    {:reply, offset, state}
  end

  def handle_call({:lines, start, count}, _from, state) do
    {:reply, Lines.slice(state.document, start, count), state}
  end

  def handle_call(:cursor, _from, state) do
    {:reply, Document.cursor(state.document), state}
  end

  def handle_call(
        {:move_if_possible, :left},
        _from,
        %{document: %Document{cursor_col: col} = doc} = state
      )
      when col > 0 do
    new_doc = Cursor.move(doc, :left)
    {:reply, {:ok, Document.cursor(new_doc)}, %{state | document: new_doc}}
  end

  def handle_call({:move_if_possible, :left}, _from, state) do
    {:reply, :at_boundary, state}
  end

  def handle_call({:move_if_possible, :right}, _from, state) do
    %Document{cursor_line: line, cursor_col: col} = doc = state.document
    max_col = right_boundary(doc, line)
    do_move_right(col, max_col, doc, state)
  end

  def handle_call(:line_count, _from, state) do
    {:reply, Document.line_count(state.document), state}
  end

  def handle_call(:dirty?, _from, state) do
    {:reply, BufState.dirty?(state), state}
  end

  def handle_call(:consume_edit_deltas, _from, state) do
    {edits, change_log} = ChangeLog.drain_pending_changes(state.change_log)
    {:reply, edits, %{state | change_log: change_log}}
  end

  def handle_call({:consume_edit_deltas, consumer_id}, _from, state) do
    {result, change_log} = ChangeLog.take_unseen_changes(state.change_log, consumer_id)
    {:reply, result, %{state | change_log: change_log}}
  end

  def handle_call(:version, _from, state) do
    {:reply, BufState.version(state), state}
  end

  def handle_call(:file_path, _from, state) do
    {:reply, state.file_path, state}
  end

  def handle_call(:filetype, _from, state) do
    {:reply, state.filetype, state}
  end

  def handle_call(:face_overrides, _from, state) do
    {:reply, state.face_overrides, state}
  end

  def handle_call({:remap_face, face_name, attrs}, _from, state) do
    overrides = Map.put(state.face_overrides, face_name, attrs)
    notify_face_overrides_changed(state, overrides)
    {:reply, :ok, %{state | face_overrides: overrides}}
  end

  def handle_call({:clear_face_override, face_name}, _from, state) do
    overrides = Map.delete(state.face_overrides, face_name)
    notify_face_overrides_changed(state, overrides)
    {:reply, :ok, %{state | face_overrides: overrides}}
  end

  def handle_call({:set_filetype, filetype}, _from, state) do
    # Reseed from the configured options server for the new filetype, but preserve any
    # options that were explicitly set via set_option (e.g., clipboard: :none
    # injected by test setup). Without this, set_filetype would wipe out
    # per-buffer overrides and re-read from the configured Config.Options.
    new_state = %{state | filetype: filetype, options: reseed_options(state, filetype)}
    {:reply, :ok, new_state}
  end

  def handle_call(:buffer_name, _from, state) do
    {:reply, state.name, state}
  end

  def handle_call(:display_name, _from, state) do
    {:reply, display_name_from_state(state), state}
  end

  def handle_call(:read_only?, _from, state) do
    {:reply, state.read_only, state}
  end

  def handle_call(:storage, _from, state) do
    {:reply, state.storage, state}
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
    case Config.validate_option(name, value) do
      :ok ->
        new_state = %{
          state
          | options: Map.put(state.options, name, value),
            explicit_options: MapSet.put(state.explicit_options, name)
        }

        {:reply, {:ok, value}, apply_option_change(new_state, name)}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:local_options, _from, state) do
    {:reply, state.options, state}
  end

  def handle_call(:local_option_overrides, _from, state) do
    overrides = Map.take(state.options, MapSet.to_list(state.explicit_options))
    {:reply, overrides, state}
  end

  def handle_call({:append, text}, _from, state) do
    content = Document.content(state.document)
    new_content = content <> text
    new_buf = Document.new(new_content)
    # Move cursor to end
    line_count = Document.line_count(new_buf)
    last_line = max(0, line_count - 1)

    last_col =
      case Lines.slice(new_buf, last_line, 1) do
        [row] -> Position.last_character_on_line(row)
        _ -> 0
      end

    new_buf = Cursor.place(new_buf, {last_line, last_col})
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call({:render_snapshot, first_line, count}, _from, state) do
    buf = state.document

    # Use position_to_offset for O(1) byte offset lookup via line index,
    # instead of iterating all lines before first_line.
    first_line_byte_offset = Position.point_for(buf, {first_line, 0})

    snapshot = %RenderSnapshot{
      cursor: Document.cursor(buf),
      line_count: Document.line_count(buf),
      lines: Lines.slice(buf, first_line, count),
      file_path: state.file_path,
      filetype: state.filetype,
      buffer_type: state.buffer_type,
      dirty: BufState.dirty?(state),
      name: state.name,
      read_only: state.read_only,
      first_line_byte_offset: first_line_byte_offset,
      version: BufState.version(state),
      options: resolved_buffer_local_options(state),
      decorations: state.decorations
    }

    {:reply, snapshot, state}
  end

  def handle_call({:delete_range, _from_pos, _to_pos}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:delete_range, from_pos, to_pos}, _from, state) do
    case Operation.delete_range(state.document, from_pos, to_pos) do
      :unchanged ->
        {:reply, :ok, state}

      {:edited, new_doc, delta} ->
        {:reply, :ok,
         push_undo(state, new_doc, :user, delta) |> mark_dirty() |> record_edit(delta)}
    end
  end

  def handle_call({:text_between_inclusive, start_pos, end_pos}, _from, state) do
    result = Document.content_between_inclusive(state.document, start_pos, end_pos)
    {:reply, result, state}
  end

  def handle_call({:content_range_length, start_pos, end_pos}, _from, state) do
    result = Document.content_range_length(state.document, start_pos, end_pos)
    {:reply, result, state}
  end

  def handle_call({:content_on_lines, start_line, end_line}, _from, state) do
    result = Document.content_on_lines(state.document, start_line, end_line)
    {:reply, result, state}
  end

  def handle_call({:delete_lines, _start_line, _end_line}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:delete_lines, start_line, end_line}, _from, state) do
    case Operation.delete_lines(state.document, start_line, end_line) do
      :unchanged ->
        {:reply, :ok, state}

      {:edited, new_doc, delta} ->
        {:reply, :ok,
         push_undo(state, new_doc, :user, delta) |> mark_dirty() |> record_edit(delta)}
    end
  end

  def handle_call(:content_and_cursor, _from, state) do
    {:reply, Document.content_and_cursor(state.document), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.document, state}
  end

  def handle_call({:commit_snapshot, _new_buf}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:commit_snapshot, new_buf}, _from, state) do
    {:reply, :ok,
     push_undo_full(state, new_buf, :user) |> mark_dirty() |> clear_edits(EditSource.user())}
  end

  def handle_call({:clear_line, _line}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:clear_line, line}, _from, state) do
    {yanked, new_buf} = Document.clear_line(state.document, line)

    if new_buf == state.document do
      {:reply, {:ok, yanked}, state}
    else
      {:reply, {:ok, yanked}, push_undo_full(state, new_buf, :user) |> mark_dirty()}
    end
  end

  def handle_call(:undo, _from, state) do
    case UndoHistory.undo(state.undo_history, BufState.version(state), state.document) do
      :empty ->
        {:reply, :ok, state}

      {:ok, restore, undo_history} ->
        event_source = EditSource.from_undo_source(restore.source)

        new_state =
          %{
            BufState.restore_version(state, restore.version)
            | document: restore.document,
              undo_history: undo_history
          }
          |> sync_dirty()
          |> clear_edits(event_source)

        log_undo_source(:undo, restore.source)
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:redo, _from, state) do
    case UndoHistory.redo(state.undo_history, BufState.version(state), state.document) do
      :empty ->
        {:reply, :ok, state}

      {:ok, restore, undo_history} ->
        event_source = EditSource.from_undo_source(restore.source)

        new_state =
          %{
            BufState.restore_version(state, restore.version)
            | document: restore.document,
              undo_history: undo_history
          }
          |> sync_dirty()
          |> clear_edits(event_source)

        log_undo_source(:redo, restore.source)
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:break_undo_coalescing, _from, state) do
    undo_history = UndoHistory.break_coalescing(state.undo_history)
    {:reply, :ok, %{state | undo_history: undo_history}}
  end

  def handle_call(:last_undo_source, _from, state) do
    {:reply, UndoHistory.last_undo_source(state.undo_history), state}
  end

  def handle_call(:last_redo_source, _from, state) do
    {:reply, UndoHistory.last_redo_source(state.undo_history), state}
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

  def handle_call({:replace_content_with_decorations, content, decoration_fn, opts}, _from, state) do
    new_doc = Document.new(content)

    # Optional cursor clamping
    new_doc =
      case Keyword.get(opts, :cursor) do
        nil -> new_doc
        {line, col} -> Cursor.place(new_doc, {line, col})
      end

    new_decs = decoration_fn.(Decorations.new())

    new_state = %{
      BufState.record_clean_change(state)
      | document: new_doc,
        undo_history: UndoHistory.clear(state.undo_history),
        change_log: ChangeLog.clear(state.change_log),
        decorations: new_decs
    }

    defer_content_replaced(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:add_virtual_text, anchor, opts}, _from, state) do
    {id, decs} = Decorations.add_virtual_text(state.decorations, anchor, opts)
    {:reply, id, %{state | decorations: decs}}
  end

  def handle_call({:remove_virtual_text, id}, _from, state) do
    decs = Decorations.remove_virtual_text(state.decorations, id)
    {:reply, :ok, %{state | decorations: decs}}
  end

  def handle_call({:add_block_decoration, anchor_line, opts}, _from, state) do
    {id, decs} = Decorations.add_block_decoration(state.decorations, anchor_line, opts)
    {:reply, id, %{state | decorations: decs}}
  end

  def handle_call({:remove_block_decoration, id}, _from, state) do
    decs = Decorations.remove_block_decoration(state.decorations, id)
    {:reply, :ok, %{state | decorations: decs}}
  end

  def handle_call(:decorations, _from, state) do
    {:reply, state.decorations, state}
  end

  def handle_call(:decorations_version, _from, state) do
    {:reply, state.decorations.version, state}
  end

  # ── Deferred broadcasts (avoid deadlock in handle_call) ──

  @impl true
  def handle_info({:deferred_broadcast, topic, payload}, state) do
    Events.broadcast(topic, payload, state.events_registry)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        :write_swap,
        %{buffer_type: :file, file_path: path, swap_dir: dir} = state
      )
      when is_binary(path) and is_binary(dir) do
    if BufState.dirty?(state) do
      start_swap_write_task(state, path, dir)
    end

    {:noreply, %{state | swap_timer: nil}}
  end

  def handle_info(:write_swap, state) do
    {:noreply, %{state | swap_timer: nil}}
  end

  def handle_info(
        {:auto_save, token},
        %{buffer_type: :file, file_path: path, auto_save_token: token} = state
      )
      when is_binary(path) do
    if BufState.dirty?(state) and auto_save_enabled?(state) do
      auto_save_file(state, path)
    else
      {:noreply, clear_auto_save_timer(state)}
    end
  end

  def handle_info({:auto_save, token}, %{auto_save_token: token} = state) do
    {:noreply, clear_auto_save_timer(state)}
  end

  def handle_info({:auto_save, _token}, state) do
    {:noreply, state}
  end

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, state) do
    # Clean up timers and swap files on orderly shutdown (buffer closed, editor quit).
    state = cancel_auto_save_timer(state)
    delete_swap_file(state)
    :ok
  end

  # ── Find and Replace helpers ──

  # ── Registry helpers ──

  @spec register_path(String.t() | nil) :: :ok
  defp register_path(nil), do: :ok

  defp register_path(path) do
    abs_path = Path.expand(path)

    case Registry.register(Minga.Buffer.Registry, abs_path, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  @spec unregister_path(String.t() | nil) :: :ok
  defp unregister_path(nil), do: :ok

  defp unregister_path(path) do
    abs_path = Path.expand(path)
    Registry.unregister(Minga.Buffer.Registry, abs_path)
    :ok
  end

  # ── Private ──

  @spec start_swap_write_task(state(), String.t(), String.t()) :: :ok
  defp start_swap_write_task(state, path, dir) do
    content = Document.content(state.document)
    swap_opts = [swap_dir: dir]

    Task.start(fn ->
      write_swap_file(path, content, swap_opts)
    end)

    :ok
  end

  @spec write_swap_file(String.t(), String.t(), keyword()) :: :ok
  defp write_swap_file(path, content, swap_opts) do
    case Minga.Session.write_swap(path, content, swap_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "Failed to write swap file for #{Path.basename(path)}: #{inspect(reason)}"
        )
    end
  end

  # Defers a :content_replaced broadcast to a subsequent handle_info turn.
  # Broadcasting inside handle_call would deadlock if any subscriber calls
  # back into this GenServer. The self-send pattern unblocks the caller
  # immediately; the broadcast happens after the reply.
  @spec defer_content_replaced(BufState.t()) :: :ok
  @spec display_name_from_state(BufState.t()) :: String.t()
  defp display_name_from_state(%{name: name, read_only: ro}) when is_binary(name) do
    name <> if(ro, do: " [RO]", else: "")
  end

  defp display_name_from_state(%{file_path: path, read_only: ro}) when is_binary(path) do
    Path.basename(path) <> if(ro, do: " [RO]", else: "")
  end

  defp display_name_from_state(_state), do: "[no file]"

  defp defer_content_replaced(state) do
    path = state.file_path || ""

    send(
      self(),
      {:deferred_broadcast, :content_replaced, %Events.BufferEvent{buffer: self(), path: path}}
    )

    :ok
  end

  # Defers a :buffer_changed broadcast with delta and source to a
  # subsequent handle_info turn. Same pattern as defer_content_replaced.
  @spec defer_buffer_changed(state(), EditDelta.t() | nil, EditSource.t()) :: :ok
  defp defer_buffer_changed(state, delta, source) do
    send(
      self(),
      {:deferred_broadcast, :buffer_changed,
       %Events.BufferChangedEvent{
         buffer: self(),
         delta: delta,
         source: source,
         version: BufState.version(state)
       }}
    )

    :ok
  end

  # Broadcasts a face_overrides_changed event so any subscriber (typically
  # the Editor) can pre-compute the merged face registry. Using Events
  # decouples Buffer.Process from the Editor module.
  @spec notify_face_overrides_changed(BufState.t(), %{String.t() => keyword()}) :: :ok
  defp notify_face_overrides_changed(state, overrides) do
    Minga.Events.broadcast(
      :face_overrides_changed,
      %Minga.Events.FaceOverridesChangedEvent{
        buffer: self(),
        overrides: overrides
      },
      state.events_registry
    )

    :ok
  end

  # Resolves an option using the chain: buffer-local → filetype → global.
  # With eager seeding, the buffer-local map already contains filetype/global
  # defaults, so the fallback path is rarely hit (only for options not in
  # the seed list, or if the Options agent was unavailable at init time).
  @spec resolve_option(BufState.t(), atom()) :: term()
  defp resolve_option(%{options: opts, filetype: ft, options_server: options_server}, name) do
    case Map.fetch(opts, name) do
      {:ok, value} -> value
      :error -> fallback_option(options_server, name, ft)
    end
  end

  @spec fallback_option(Minga.Config.Options.server() | nil, atom(), atom() | nil) :: term()
  defp fallback_option(options_server, name, filetype) do
    case safe_get_for_filetype(options_server, name, filetype) do
      {:ok, value} -> value
      :error -> Minga.Config.Options.default(name)
    end
  end

  @spec safe_get_for_filetype(Minga.Config.Options.server() | nil, atom(), atom() | nil) ::
          {:ok, term()} | :error
  defp safe_get_for_filetype(nil, name, filetype),
    do: safe_get_for_filetype(Minga.Config.Options.default_server(), name, filetype)

  defp safe_get_for_filetype(server, name, filetype) when is_pid(server) do
    if Process.alive?(server) do
      {:ok, Minga.Config.Options.get_for_filetype(server, name, filetype)}
    else
      :error
    end
  end

  defp safe_get_for_filetype(server, name, filetype) when is_atom(server) do
    table = :"#{server}_ets"

    if :ets.whereis(table) == :undefined do
      :error
    else
      {:ok, Minga.Config.Options.get_for_filetype(server, name, filetype)}
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
    :autopair_block,
    :clipboard,
    :show_invisible,
    :trim_trailing_whitespace,
    :insert_final_newline,
    :format_on_save,
    :auto_save_delay_ms,
    :formatter,
    :line_numbers
  ]

  @spec resolved_buffer_local_options(state()) :: %{atom() => term()}
  defp resolved_buffer_local_options(state) do
    Map.new(@buffer_local_options, fn name -> {name, resolve_option(state, name)} end)
  end

  @spec normalize_options_server(term() | nil) :: Minga.Config.Options.server()
  defp normalize_options_server(nil), do: Minga.Config.Options.default_server()
  defp normalize_options_server(server), do: Minga.Config.Options.validate_server!(server)

  @spec seed_options(Minga.Config.Options.server() | nil, atom()) :: %{atom() => term()}
  defp seed_options(options_server, filetype) do
    Map.new(@buffer_local_options, fn name ->
      {name,
       case safe_get_for_filetype(options_server, name, filetype) do
         {:ok, value} -> value
         :error -> Minga.Config.Options.default(name)
       end}
    end)
  end

  @spec reseed_options(BufState.t(), atom()) :: %{atom() => term()}
  defp reseed_options(%{options: options, explicit_options: explicit_options} = state, filetype) do
    explicit_values = Map.take(options, MapSet.to_list(explicit_options))

    seed_options(state.options_server, filetype)
    |> Map.merge(explicit_values)
  end

  @spec push_undo(state(), Document.t(), BufState.edit_source(), EditDelta.t()) :: state()
  defp push_undo(state, new_buf, source, delta) do
    patch = UndoPatch.from_delta(delta, state.document)

    undo_history =
      UndoHistory.record_edit(state.undo_history, BufState.version(state), patch, source)

    %{state | document: new_buf, undo_history: undo_history}
  end

  @spec push_undo_full(state(), Document.t(), BufState.edit_source()) :: state()
  defp push_undo_full(state, new_buf, source) do
    patch = UndoPatch.from_documents(state.document, new_buf)

    undo_history =
      UndoHistory.record_edit(state.undo_history, BufState.version(state), patch, source)

    %{state | document: new_buf, undo_history: undo_history}
  end

  @spec push_undo_batch(state(), Document.t(), BufState.edit_source(), [UndoPatch.t()]) :: state()
  defp push_undo_batch(state, new_buf, source, patches) do
    undo_history =
      UndoHistory.record_edit_batch(state.undo_history, BufState.version(state), patches, source)

    %{state | document: new_buf, undo_history: undo_history}
  end

  @spec push_undo_force_full(state(), Document.t(), BufState.edit_source()) :: state()
  defp push_undo_force_full(state, new_buf, source) do
    patch = UndoPatch.from_documents(state.document, new_buf)

    undo_history =
      UndoHistory.record_edit_force(state.undo_history, BufState.version(state), patch, source)

    %{state | document: new_buf, undo_history: undo_history}
  end

  # Logs undo/redo source for non-user edits (diagnostic, gated by :log_level_editor).
  @spec log_undo_source(:undo | :redo, BufState.edit_source()) :: :ok
  defp log_undo_source(_action, :user), do: :ok

  defp log_undo_source(:undo, source) do
    Minga.Log.debug(:editor, "Undo: #{source} edit")
  end

  defp log_undo_source(:redo, source) do
    Minga.Log.debug(:editor, "Redo: #{source} edit")
  end

  @swap_debounce_ms 5_000

  @spec mark_dirty(state()) :: state()
  defp mark_dirty(state) do
    state = BufState.mark_dirty(state)
    state = schedule_swap_write(state)
    schedule_auto_save(state)
  end

  @spec sync_dirty(state()) :: state()
  defp sync_dirty(state) do
    state = BufState.sync_dirty(state)

    if BufState.dirty?(state) do
      schedule_auto_save(state)
    else
      cancel_auto_save_timer(state)
    end
  end

  @spec mark_saved(state(), Minga.Buffer.SaveState.metadata(), String.t()) :: state()
  defp mark_saved(state, metadata, content) do
    state = BufState.mark_saved(state, metadata, content)
    :ok = delete_swap_file(state)
    state = cancel_swap_timer(state)
    cancel_auto_save_timer(state)
  end

  # Schedule a debounced swap file write. Cancels any pending timer
  # so rapid edits only produce one write after 5 seconds of quiet.
  @spec schedule_swap_write(state()) :: state()
  defp schedule_swap_write(%{buffer_type: :file, file_path: path, swap_dir: dir} = state)
       when is_binary(path) and is_binary(dir) do
    state = cancel_swap_timer(state)
    ref = Process.send_after(self(), :write_swap, @swap_debounce_ms)
    %{state | swap_timer: ref}
  end

  defp schedule_swap_write(state), do: state

  @spec cancel_swap_timer(state()) :: state()
  defp cancel_swap_timer(%{swap_timer: nil} = state), do: state

  defp cancel_swap_timer(%{swap_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | swap_timer: nil}
  end

  @spec apply_option_change(state(), atom()) :: state()
  defp apply_option_change(state, :auto_save_delay_ms) do
    if BufState.dirty?(state), do: schedule_auto_save(state), else: cancel_auto_save_timer(state)
  end

  defp apply_option_change(state, _name), do: state

  @spec auto_save_file(state(), String.t()) :: {:noreply, state()}
  defp auto_save_file(state, path) do
    case Persistence.file_info(state, path) do
      {:ok, %{mtime: disk_mtime, size: disk_size}} ->
        maybe_write_auto_save_file(state, path, disk_mtime, disk_size)

      {:error, :enoent} ->
        if is_nil(BufState.mtime(state)) do
          write_auto_save_file(state, path)
        else
          skip_auto_save(state, path, "file was deleted on disk")
        end

      {:error, reason} ->
        skip_auto_save(state, path, "could not stat file: #{inspect(reason)}")
    end
  end

  @spec maybe_write_auto_save_file(state(), String.t(), integer(), non_neg_integer()) ::
          {:noreply, state()}
  defp maybe_write_auto_save_file(state, path, disk_mtime, disk_size) do
    if Persistence.changed_since_saved?(state, disk_mtime, disk_size) do
      skip_auto_save(state, path, "file changed on disk")
    else
      write_auto_save_file(state, path)
    end
  end

  @spec skip_auto_save(state(), String.t(), String.t()) :: {:noreply, state()}
  defp skip_auto_save(state, path, reason) do
    log_to_messages(
      state,
      "Auto-save skipped for #{display_path(path)}: #{reason}; reload or save explicitly.",
      :warning
    )

    {:noreply, clear_auto_save_timer(state)}
  end

  @spec write_auto_save_file(state(), String.t()) :: {:noreply, state()}
  defp write_auto_save_file(state, path) do
    content = Document.content(state.document)

    case Persistence.write_content(state, path, content) do
      :ok ->
        {new_mtime, new_size} = Persistence.file_metadata(state, path)

        new_state = mark_saved(state, {new_mtime, new_size}, content)

        log_to_messages(new_state, "Auto-saved: #{display_path(path)}", :info)
        broadcast_buffer_saved(new_state, path)
        {:noreply, new_state}

      {:error, reason} ->
        log_to_messages(
          state,
          "Failed to auto-save #{display_path(path)}: #{inspect(reason)}",
          :warning
        )

        {:noreply, clear_auto_save_timer(state)}
    end
  end

  @spec broadcast_buffer_saved(state(), String.t()) :: :ok
  defp broadcast_buffer_saved(state, path) do
    Events.broadcast(
      :buffer_saved,
      %Events.BufferEvent{buffer: self(), path: path},
      state.events_registry
    )
  end

  @spec log_to_messages(state(), String.t(), Events.LogMessageEvent.level()) :: :ok
  defp log_to_messages(state, text, level) do
    Events.broadcast(
      :log_message,
      %Events.LogMessageEvent{text: text, level: level},
      state.events_registry
    )
  end

  @spec display_path(String.t()) :: String.t()
  defp display_path(path), do: Path.relative_to_cwd(path)

  @spec auto_save_enabled?(state()) :: boolean()
  defp auto_save_enabled?(state) do
    case resolve_option(state, :auto_save_delay_ms) do
      delay when is_integer(delay) and delay > 0 -> true
      _ -> false
    end
  end

  # Schedule a debounced auto-save. A value of 0 disables auto-save.
  @spec schedule_auto_save(state()) :: state()
  defp schedule_auto_save(%{buffer_type: :file, file_path: path} = state) when is_binary(path) do
    delay_ms = resolve_option(state, :auto_save_delay_ms)

    case delay_ms do
      delay when is_integer(delay) and delay > 0 ->
        state = cancel_auto_save_timer(state)
        token = make_ref()
        timer = Process.send_after(self(), {:auto_save, token}, delay)
        %{state | auto_save_timer: timer, auto_save_token: token}

      _ ->
        cancel_auto_save_timer(state)
    end
  end

  defp schedule_auto_save(state), do: state

  @spec cancel_auto_save_timer(state()) :: state()
  defp cancel_auto_save_timer(%{auto_save_timer: nil} = state), do: clear_auto_save_timer(state)

  defp cancel_auto_save_timer(%{auto_save_timer: timer, auto_save_token: token} = state)
       when is_reference(timer) and is_reference(token) do
    Process.cancel_timer(timer)
    flush_auto_save_message(token)
    clear_auto_save_timer(state)
  end

  @spec clear_auto_save_timer(state()) :: state()
  defp clear_auto_save_timer(state), do: %{state | auto_save_timer: nil, auto_save_token: nil}

  @spec flush_auto_save_message(reference()) :: :ok
  defp flush_auto_save_message(token) do
    receive do
      {:auto_save, ^token} -> :ok
    after
      0 -> :ok
    end
  end

  @spec delete_swap_file(state()) :: :ok
  defp delete_swap_file(%{file_path: path, swap_dir: dir})
       when is_binary(path) and is_binary(dir) do
    Minga.Session.delete_swap(path, swap_dir: dir)
  end

  defp delete_swap_file(_state), do: :ok

  # ── Edit delta tracking ──

  @spec record_edit(state(), EditDelta.t()) :: state()
  defp record_edit(state, delta) do
    record_edit(state, delta, EditSource.user())
  end

  @spec record_edit(state(), EditDelta.t(), EditSource.t()) :: state()
  defp record_edit(state, delta, source) do
    state = %{state | change_log: ChangeLog.record_change(state.change_log, delta)}

    # Adjust decoration anchors based on the edit
    state =
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

    defer_buffer_changed(state, delta, source)
    state
  end

  # Clear pending edits to force HighlightSync into full content sync.
  # Used for operations where computing accurate deltas is impractical
  # (undo, redo, multi-edit batches, full content replacement).
  @spec clear_edits(state(), EditSource.t()) :: state()
  defp clear_edits(state, source) do
    defer_buffer_changed(state, nil, source)
    %{state | change_log: ChangeLog.clear(state.change_log)}
  end

  # ── move_if_possible helpers ──

  @spec right_boundary(Document.t(), non_neg_integer()) :: non_neg_integer()
  defp right_boundary(doc, line) do
    case Lines.slice(doc, line, 1) do
      [text] when byte_size(text) > 0 -> Position.last_character_on_line(text)
      _ -> 0
    end
  end

  @spec do_move_right(non_neg_integer(), non_neg_integer(), Document.t(), BufState.t()) ::
          {:reply, {:ok, Document.position()} | :at_boundary, BufState.t()}
  defp do_move_right(col, max_col, doc, state) when col < max_col do
    new_doc = Cursor.move(doc, :right)
    {:reply, {:ok, Document.cursor(new_doc)}, %{state | document: new_doc}}
  end

  defp do_move_right(_col, _max_col, _doc, state) do
    {:reply, :at_boundary, state}
  end
end
