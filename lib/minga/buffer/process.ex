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
    Conflict,
    ConflictIndex,
    Cursor,
    CursorContext,
    Document,
    FileMutation,
    InspectionSnapshot,
    Lines,
    Operation,
    Persistence,
    Position,
    Replace,
    SaveIntent,
    UndoHistory,
    UndoPatch
  }

  alias Minga.Buffer.Author
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Persistence.SystemFileSystem
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.State.LocalPersistence
  alias Minga.Buffer.State.Swap, as: SwapState
  alias Minga.Buffer.UndoHistory.Restore
  alias Minga.Config
  alias Minga.Core.Decorations
  alias Minga.Core.PositionEncoding
  alias Minga.Core.Unicode
  alias Minga.Events
  alias Minga.Git.MergeConflict
  alias Minga.Git.MergeConflict.Entry
  alias Minga.Language

  alias Minga.Buffer.State, as: BufState

  require Author
  import EditSource, only: [is_undo_source: 1]

  @typedoc "Options for starting a buffer server."
  @type start_opt ::
          {:file_path, String.t()}
          | {:content, String.t()}
          | {:name, GenServer.name()}
          | {:buffer_name, String.t()}
          | {:buffer_type, BufState.buffer_type()}
          | {:storage, BufState.storage()}
          | {:persistence_file_system, module()}
          | {:persistence_file_system_options, keyword()}
          | {:filetype, atom()}
          | {:options_server, Minga.Config.Options.server() | nil}
          | {:read_only, boolean()}
          | {:unlisted, boolean()}
          | {:persistent, boolean()}
          | {:swap_dir, String.t() | nil}
          | {:swap_backend, module()}
          | {:swap_backend_options, keyword()}
          | {:swap_timer_start, SwapState.timer_start()}
          | {:events_registry, Minga.Events.registry()}

  @typedoc "Internal state of the buffer server."
  @type state :: BufState.t()
  @type edit_delta_update :: {:ok, [EditDelta.t()]} | :reset_required
  @type motion_fun :: (Document.t(), Document.position() -> Document.position())
  @type listing_info :: %{
          name: String.t() | nil,
          file_path: String.t() | nil,
          filetype: atom(),
          unlisted: boolean(),
          read_only: boolean(),
          dirty: boolean()
        }
  @typep operation_result ::
           {:delta, Document.t(), EditDelta.t()}
           | {:full, Document.t()}
           | {:batch, Document.t(), [UndoPatch.t()]}
           | {:changes, Document.t(), nonempty_list(UndoPatch.t())}
  @typep operation_undo :: :full | :batch | :changes | :force_delta | :force_full
  @typep operation_sync :: :record_delta | :clear
  @typep operation_opts :: {operation_undo(), BufState.edit_source(), operation_sync()}

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

  The whole string is inserted in one buffer operation, advancing the cursor to the end.
  """
  @spec insert_text(GenServer.server(), String.t(), EditSource.t()) ::
          :ok | {:error, :read_only}
  def insert_text(server, text, source \\ EditSource.user()) do
    GenServer.call(server, {:insert_text, text, source})
  end

  @doc """
  Replaces a characterwise inclusive range with new text, as one undo entry.

  The range and the cursor follow `Minga.Buffer.Operation.replace_range/4`. Returns `{:error, :invalid_utf8}` when the result would not be valid UTF-8, for example because a column falls inside a multi-byte code point, and `{:error, :malformed_edit}` when a position or the replacement has the wrong shape. The buffer is unchanged on every error.
  """
  @spec apply_edit(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          EditSource.t()
        ) :: :ok | {:error, :read_only | Operation.edit_error()}
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

  @doc "Replaces complete lines, adding a separator only when the replacement needs one before an unselected following line."
  @spec replace_lines(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          EditSource.t()
        ) :: :ok | {:error, :read_only}
  def replace_lines(server, start_line, end_line, new_text, source \\ EditSource.user())
      when start_line >= 0 and end_line >= 0 and is_binary(new_text) do
    GenServer.call(server, {:replace_lines, start_line, end_line, new_text, source})
  end

  @doc "Atomically replaces a half-open byte range as its own undo entry when the buffer version is current."
  @spec replace_byte_range_if_version(
          GenServer.server(),
          non_neg_integer(),
          Document.position(),
          non_neg_integer(),
          String.t(),
          EditSource.t()
        ) :: {:ok, non_neg_integer()} | {:error, :invalid_range | :read_only | :stale}
  def replace_byte_range_if_version(
        server,
        expected_version,
        position,
        byte_length,
        replacement,
        source \\ EditSource.user()
      )
      when is_integer(expected_version) and expected_version >= 0 and
             is_integer(byte_length) and byte_length >= 0 and is_binary(replacement) do
    GenServer.call(
      server,
      {:replace_byte_range_if_version, expected_version, position, byte_length, replacement,
       source}
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
  function sorts them automatically. Each edit follows
  `Minga.Buffer.Operation.replace_range/4`: a column past its line's end
  means the line end.

  Returns `{:error, {:edit_failed, index, :invalid_utf8}}`, and changes
  nothing, when the buffer is not valid UTF-8 or the edit at `index` in
  `edits` would leave it invalid, for example overlapping edits that split
  a code point. Returns `{:error, {:edit_failed, index, :malformed_edit}}`,
  and changes nothing, when the edit at `index` is not a
  `{{line, col}, {line, col}, text}` tuple with non-negative integer
  positions and a binary text.

  Used by AI/LSP batch operations to avoid N round-trips and N undo entries.

  Source defaults to `{:lsp, :unknown}` (not `:user`) because batch edits
  are typically LSP code actions or agent tool calls, not interactive typing.
  """
  @spec apply_edits(GenServer.server(), [text_edit()], EditSource.t()) ::
          :ok | {:error, :read_only | Operation.batch_error()}
  def apply_edits(server, edits, source \\ EditSource.lsp(:unknown)) when is_list(edits) do
    GenServer.call(server, {:apply_edits, edits, source})
  end

  @doc """
  Shifts every line from `start_line` to `end_line` by one indentation level as one edit.

  The shift is one undo step and one document edit. Change-log consumers and `:buffer_changed` subscribers still receive one delta per changed line, each with its own version and sequence, in the order a line-by-line edit would have produced them. See `Minga.Buffer.Operation.shift_lines/4`.
  """
  @spec shift_lines(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          Operation.line_shift(),
          EditSource.t()
        ) :: :ok | {:error, :read_only}
  def shift_lines(server, start_line, end_line, shift, source \\ EditSource.user())
      when is_integer(start_line) and start_line >= 0 and is_integer(end_line) and
             end_line >= start_line do
    GenServer.call(server, {:shift_lines, start_line, end_line, shift, source})
  end

  @doc """
  Atomically finds and replaces text in the buffer, recording `source` as the edit's author.

  The search, ambiguity check, and replacement all happen inside a single
  `handle_call`, so there is no TOCTOU race between reading content and
  applying the edit. Returns `{:ok, message}` on success, or `{:error, reason}`
  if the text is not found, is ambiguous (multiple matches), or the buffer
  is read-only. Minga passes its author key (`Minga.Buffer.EditSource.minga/2`).
  """
  @typedoc "An edit boundary as `{start_line, end_line}` (both inclusive, 0-indexed), or nil for unbounded."
  @type boundary :: {non_neg_integer(), non_neg_integer()} | nil

  @spec find_and_replace(
          GenServer.server(),
          String.t(),
          String.t(),
          BufState.edit_source(),
          boundary()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def find_and_replace(server, old_text, new_text, source, boundary \\ nil)
      when is_undo_source(source) do
    GenServer.call(server, {:find_and_replace, old_text, new_text, boundary, source})
  end

  @doc """
  Checks the full source revision and prepares and commits a file mutation in
  the owning callback. A successful mutation is one undo entry attributed to
  `source`, with one patch per changed region; errors leave content, version
  and undo history unchanged. Buffer creation and deletion require the
  changeset lifecycle and are not supported here.
  """
  @spec conditional_mutate(
          GenServer.server(),
          FileMutation.expectation(),
          FileMutation.operation(),
          FileMutation.identity(),
          BufState.edit_source()
        ) :: {:ok, FileMutation.Receipt.t()} | {:error, term()}
  def conditional_mutate(server, expected, operation, identity, source)
      when is_undo_source(source) do
    GenServer.call(
      server,
      {:conditional_mutate, expected, operation, identity, source},
      :infinity
    )
  end

  @doc """
  Merges fork content against the current parent, optionally staging the raw fork
  draft before installing the merge. Staging runs under parent ownership and
  failure leaves the parent unchanged. The merge is one undo entry attributed
  to `source`, with one patch per changed region.
  """
  @spec merge_fork(
          GenServer.server(),
          String.t(),
          String.t(),
          BufState.edit_source(),
          (String.t() -> :ok | {:conflict, term()} | {:error, term()}) | nil
        ) :: {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  def merge_fork(server, ancestor, fork_content, source, staging \\ nil)
      when is_undo_source(source) and (is_nil(staging) or is_function(staging, 1)) do
    GenServer.call(server, {:merge_fork, ancestor, fork_content, staging, source}, :infinity)
  end

  @doc """
  Installs a resolved fork only at the reviewed parent revision, after staging succeeds.

  The installation is one undo entry attributed to `source`, with one patch per changed region.
  """
  @spec install_fork_resolution(
          GenServer.server(),
          non_neg_integer(),
          String.t(),
          String.t(),
          (String.t() -> :ok | {:conflict, term()} | {:error, term()}),
          BufState.edit_source()
        ) :: {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  def install_fork_resolution(server, version, merged, fork_content, staging, source)
      when is_undo_source(source) do
    GenServer.call(
      server,
      {:install_fork_resolution, version, merged, fork_content, staging, source},
      :infinity
    )
  end

  @doc "Publishes deletion under parent ownership without discarding the open buffer's bytes."
  @spec publish_fork_deletion(
          GenServer.server(),
          String.t(),
          (-> :ok | {:conflict, term()} | {:error, term()})
        ) :: :ok | {:conflict, term()} | {:error, term()}
  def publish_fork_deletion(server, ancestor, publication) when is_function(publication, 0) do
    GenServer.call(server, {:publish_fork_deletion, ancestor, publication}, :infinity)
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

  @doc "Moves to an exact byte position only while the expected content revision is current."
  @spec move_to_if_version(GenServer.server(), non_neg_integer(), Document.position()) ::
          {:ok, Document.position()} | {:error, :stale | :position_out_of_range}
  def move_to_if_version(server, version, {line, col} = position)
      when is_integer(version) and version >= 0 and is_integer(line) and line >= 0 and
             is_integer(col) and col >= 0 do
    GenServer.call(server, {:move_to_if_version, version, position})
  end

  @doc "Validates an exact byte position without moving the cursor."
  @spec resolve_position_if_version(GenServer.server(), non_neg_integer(), Document.position()) ::
          {:ok, Document.position()} | {:error, :stale | :position_out_of_range}
  def resolve_position_if_version(server, version, {line, col} = position)
      when is_integer(version) and version >= 0 and is_integer(line) and line >= 0 and
             is_integer(col) and col >= 0 do
    GenServer.call(server, {:resolve_position_if_version, version, position})
  end

  @doc "Moves to an exact external UTF-16 position only while the expected content revision is current."
  @spec move_to_utf16_if_version(
          GenServer.server(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, Document.position()}
          | {:error, :stale | :line_out_of_range | :column_out_of_range | :column_not_boundary}
  def move_to_utf16_if_version(server, version, line, column)
      when is_integer(version) and version >= 0 and is_integer(line) and line > 0 and
             is_integer(column) and column >= 0 do
    GenServer.call(server, {:move_to_utf16_if_version, version, line, column})
  end

  @doc "Resolves an exact external UTF-16 position without moving the cursor."
  @spec resolve_utf16_position_if_version(
          GenServer.server(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, Document.position()}
          | {:error, :stale | :line_out_of_range | :column_out_of_range | :column_not_boundary}
  def resolve_utf16_position_if_version(server, version, line, column)
      when is_integer(version) and version >= 0 and is_integer(line) and line > 0 and
             is_integer(column) and column >= 0 do
    GenServer.call(server, {:resolve_utf16_position_if_version, version, line, column})
  end

  @doc "Applies a cursor motion inside the buffer process."
  @spec apply_motion(GenServer.server(), motion_fun()) :: :ok
  def apply_motion(server, motion_fn) when is_function(motion_fn, 2) do
    GenServer.call(server, {:apply_motion, motion_fn})
  end

  @file_io_call_timeout 30_000

  @doc "Saves the buffer content to the associated file."
  @spec save(GenServer.server()) :: :ok | {:error, term()}
  def save(server) do
    GenServer.call(server, :save, @file_io_call_timeout)
  end

  @doc "Saves the buffer content to the associated file only when the version matches."
  @spec save_if_version(GenServer.server(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def save_if_version(server, expected_version, opts \\ [])
      when is_integer(expected_version) and expected_version >= 0 and is_list(opts) do
    GenServer.call(server, {:save_if_version, expected_version, opts}, @file_io_call_timeout)
  end

  @doc "Force-saves the buffer, skipping mtime conflict detection."
  @spec force_save(GenServer.server()) :: :ok | {:error, term()}
  def force_save(server) do
    GenServer.call(server, :force_save, @file_io_call_timeout)
  end

  @doc "Captures the target and overwrite policy for an explicit-path save."
  @spec prepare_save_as(GenServer.server(), String.t(), boolean()) ::
          {:ok, SaveIntent.t()} | {:error, term()}
  def prepare_save_as(server, file_path, overwrite)
      when is_binary(file_path) and is_boolean(overwrite) do
    GenServer.call(server, {:prepare_save_as, file_path, overwrite}, @file_io_call_timeout)
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

  @doc "Saves the buffer to a specific file path only when the version matches."
  @spec save_as_if_version(
          GenServer.server(),
          non_neg_integer(),
          SaveIntent.t(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def save_as_if_version(server, expected_version, %SaveIntent{} = intent, opts \\ [])
      when is_integer(expected_version) and expected_version >= 0 and
             is_list(opts) do
    GenServer.call(
      server,
      {:save_as_if_version, expected_version, intent, opts},
      @file_io_call_timeout
    )
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

  @doc """
  Gives the buffer the unsaved text that was read from the swap file at `swap_path`, and makes this buffer the owner of that text.

  The buffer takes the text, writes its own swap file at once, and only then removes `swap_path`. A second crash before the next debounced write therefore still finds the text on disk. When the buffer's own swap cannot be written, `swap_path` stays where it is.

  A buffer that already has unsaved changes holds newer text and refuses with `{:error, :modified}`. A buffer that writes no swap files takes the text and removes `swap_path`, because nothing else would ever remove it.
  """
  @spec adopt_recovered_text(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :read_only | :modified}
  def adopt_recovered_text(server, content, swap_path)
      when is_binary(content) and is_binary(swap_path) do
    GenServer.call(server, {:adopt_recovered_text, content, swap_path}, @file_io_call_timeout)
  end

  # A quit must not wait long on a buffer that is busy with slow file work.
  @swap_release_timeout 2_000

  @doc """
  Stops swap writes and removes this buffer's swap file in `swap_dir`, because the user is quitting on purpose.

  The call gives up after `timeout` (2 seconds by default). A buffer that did not answer keeps its swap file, and the next start offers that text again: that is better than a quit that hangs.

  The supervisor stops buffers without running `terminate/2`, so a quit has to ask. After this call the buffer writes no swap file again. A buffer that writes into another directory, or writes no swap files, is left as it is.
  """
  @spec release_swap(GenServer.server(), String.t(), timeout()) :: :ok
  def release_swap(server, swap_dir, timeout \\ @swap_release_timeout) when is_binary(swap_dir),
    do: GenServer.call(server, {:release_swap, swap_dir}, timeout)

  @doc "Atomically replaces content at `expected_version`, preserving the nearest valid cursor position."
  @spec replace_content_if_version(
          GenServer.server(),
          non_neg_integer(),
          String.t(),
          BufState.edit_source()
        ) :: {:ok, non_neg_integer()} | {:error, :read_only | :stale}
  def replace_content_if_version(server, expected_version, new_content, source \\ :user)
      when is_integer(expected_version) and expected_version >= 0 and is_binary(new_content) and
             is_undo_source(source) do
    GenServer.call(server, {:replace_content_if_version, expected_version, new_content, source})
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

  @doc """
  Marks the buffer saved when its content already equals the file on disk.

  Used after another owner (for example, an agent edit publication) wrote the buffer's exact content to its file. Content, cursor, and undo history are untouched. Returns `{:error, :content_differs}` and leaves the buffer dirty when disk and buffer disagree, so unsaved user edits are never hidden.
  """
  @spec mark_saved_if_disk_matches(GenServer.server()) ::
          :ok | {:error, :content_differs | :no_file_path | term()}
  def mark_saved_if_disk_matches(server) do
    GenServer.call(server, :mark_saved_if_disk_matches, @file_io_call_timeout)
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

  @doc "Returns content and mutation version atomically in one call."
  @spec content_with_version(GenServer.server()) :: {String.t(), non_neg_integer()}
  def content_with_version(server) do
    GenServer.call(server, :content_with_version)
  end

  @doc "Returns path, text, cursor, and edit version in one buffer observation."
  @spec file_observation(GenServer.server()) ::
          {String.t() | nil, String.t(), Document.position(), non_neg_integer()}
  def file_observation(server), do: GenServer.call(server, :file_observation)

  @doc "Returns the complete text and file path from one buffer state only if the text fits."
  @spec bounded_content_with_path(GenServer.server(), non_neg_integer()) ::
          {:ok, String.t(), String.t() | nil} | {:error, :too_large}
  def bounded_content_with_path(server, max_bytes)
      when is_integer(max_bytes) and max_bytes >= 0 do
    GenServer.call(server, {:bounded_content_with_path, max_bytes})
  end

  @doc "Returns a byte-bounded prefix, mutation version, and whether it is the whole buffer."
  @spec content_prefix_with_version(GenServer.server(), non_neg_integer()) ::
          {binary(), non_neg_integer(), boolean()}
  def content_prefix_with_version(server, max_bytes) when max_bytes >= 0 do
    GenServer.call(server, {:content_prefix_with_version, max_bytes})
  end

  @doc "Returns the buffer-owned merge conflict entries."
  @spec conflicts(GenServer.server()) :: [Minga.Git.MergeConflict.Entry.t()]
  def conflicts(server), do: GenServer.call(server, :conflicts)

  @doc "Returns the buffer-owned merge conflict count."
  @spec conflict_count(GenServer.server()) :: non_neg_integer()
  def conflict_count(server), do: GenServer.call(server, :conflict_count)

  @doc "Returns content, cursor, and merge conflict entries from one buffer state."
  @spec conflict_snapshot(GenServer.server()) ::
          {String.t(), Document.position(), [Minga.Git.MergeConflict.Entry.t()]}
  def conflict_snapshot(server), do: GenServer.call(server, :conflict_snapshot)

  @doc "Returns the current version and conflict markers used by the renderer."
  @spec conflict_render_snapshot(GenServer.server()) :: {non_neg_integer(), [Entry.t()]}
  def conflict_render_snapshot(server), do: GenServer.call(server, :conflict_render_snapshot)

  @doc "Returns the cursor, public conflict regions, and version from one buffer state."
  @spec conflict_view(GenServer.server()) :: Conflict.view()
  def conflict_view(server), do: GenServer.call(server, :conflict_view)

  @doc "Resolves one indexed conflict when its observed buffer version still matches."
  @spec resolve_conflict(
          GenServer.server(),
          non_neg_integer(),
          Conflict.target(),
          Conflict.choice()
        ) :: {:ok, Conflict.resolution()} | {:error, Conflict.rejection()}
  def resolve_conflict(server, expected_version, target, choice)
      when is_integer(expected_version) and expected_version >= 0 and
             choice in [:current, :incoming, :both] do
    case target do
      {:cursor, line} when is_integer(line) and line >= 0 ->
        GenServer.call(server, {:resolve_conflict, expected_version, target, choice})

      {:region, %{start_line: start_line, end_line: end_line}}
      when is_integer(start_line) and is_integer(end_line) and start_line >= 0 and
             end_line >= start_line ->
        GenServer.call(server, {:resolve_conflict, expected_version, target, choice})
    end
  end

  @doc "Returns bounded semantic inspection data from one coherent buffer state."
  @spec inspection_snapshot(GenServer.server(), non_neg_integer(), pos_integer()) ::
          InspectionSnapshot.t()
  def inspection_snapshot(server, viewport_start, viewport_count)
      when is_integer(viewport_start) and viewport_start >= 0 and is_integer(viewport_count) and
             viewport_count > 0 do
    GenServer.call(server, {:inspection_snapshot, viewport_start, viewport_count})
  end

  @doc "Returns one coherent inspection snapshot using the live or supplied window cursor."
  @spec inspection_snapshot(
          GenServer.server(),
          non_neg_integer(),
          pos_integer(),
          :live | Document.position()
        ) :: InspectionSnapshot.t()
  def inspection_snapshot(server, viewport_start, viewport_count, :live)
      when is_integer(viewport_start) and viewport_start >= 0 and is_integer(viewport_count) and
             viewport_count > 0 do
    GenServer.call(server, {:inspection_snapshot, viewport_start, viewport_count, :live})
  end

  def inspection_snapshot(server, viewport_start, viewport_count, {line, column} = cursor)
      when is_integer(viewport_start) and viewport_start >= 0 and is_integer(viewport_count) and
             viewport_count > 0 and is_integer(line) and line >= 0 and is_integer(column) and
             column >= 0 do
    GenServer.call(server, {:inspection_snapshot, viewport_start, viewport_count, cursor})
  end

  @doc "Returns a coherent content revision and cursor marker for semantic inspection freshness."
  @spec inspection_marker(GenServer.server()) :: {non_neg_integer(), Document.position()}
  def inspection_marker(server), do: GenServer.call(server, :inspection_marker)

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

  @doc "Fetches a sparse set of lines from one document state. Invalid indices raise in the caller."
  @spec lines_at(GenServer.server(), [non_neg_integer()]) :: %{non_neg_integer() => String.t()}
  def lines_at(server, line_numbers) when is_list(line_numbers) do
    unless Enum.all?(line_numbers, &(is_integer(&1) and &1 >= 0)) do
      raise ArgumentError, "expected non-negative integer line numbers"
    end

    GenServer.call(server, {:lines_at, line_numbers})
  end

  @doc "Returns the current cursor position."
  @spec cursor(GenServer.server()) :: Document.position()
  def cursor(server) do
    GenServer.call(server, :cursor)
  end

  @doc "Returns one coherent cursor-local snapshot for completion and movement work."
  @spec cursor_context(GenServer.server()) :: CursorContext.t()
  def cursor_context(server) do
    GenServer.call(server, :cursor_context)
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

  @doc "Returns the buffer content size in bytes (gap-buffer halves summed, O(1))."
  @spec content_byte_size(GenServer.server()) :: non_neg_integer()
  def content_byte_size(server), do: GenServer.call(server, :content_byte_size)

  @doc "Returns whether the buffer has unsaved changes."
  @spec dirty?(GenServer.server()) :: boolean()
  def dirty?(server), do: GenServer.call(server, :dirty?)

  @doc "Returns the buffer's mutation version counter (increments on every content change)."
  @spec version(GenServer.server()) :: non_neg_integer()
  def version(server), do: GenServer.call(server, :version)

  @doc "Marks the matching scratch revision saved without replacing text or undo history."
  @spec confirm_scratch_save(GenServer.server(), non_neg_integer()) :: :ok | :stale
  def confirm_scratch_save(server, version),
    do: GenServer.call(server, {:confirm_scratch_save, version})

  @doc "Returns a non-mutating sequence-qualified change query."
  @spec changes_since(GenServer.server(), Minga.Buffer.ChangeLog.sequence()) ::
          Minga.Buffer.ChangeLog.sequence_changes()
  def changes_since(server, sequence) do
    GenServer.call(server, {:changes_since, sequence})
  end

  @doc "Returns the atomic content version and monotonic change sequence."
  @spec sync_revision(GenServer.server()) ::
          {non_neg_integer(), Minga.Buffer.ChangeLog.sequence()}
  def sync_revision(server), do: GenServer.call(server, :sync_revision)

  @doc "Requests an atomic synchronization snapshot and replies asynchronously to `reply_to`."
  @spec request_sync_snapshot(
          GenServer.server(),
          :full | Minga.Buffer.ChangeLog.sequence(),
          pid(),
          reference()
        ) :: :ok
  def request_sync_snapshot(server, cursor, reply_to, token)
      when (cursor == :full or (is_integer(cursor) and cursor >= 0)) and is_pid(reply_to) and
             is_reference(token) do
    send(server, {:request_sync_snapshot, cursor, reply_to, token})
    :ok
  end

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
  @spec consume_edit_deltas(GenServer.server(), Minga.Buffer.ChangeLog.consumer()) ::
          edit_delta_update()
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
      [{pid, _value}] -> live(pid)
      [] -> :not_found
    end
  end

  # The registry drops a buffer's entry a moment after the buffer exits, so a lookup right after a crash
  # can still name the dead process. A dead buffer is not a buffer for the path.
  @spec live(pid()) :: {:ok, pid()} | :not_found
  defp live(pid), do: if(Process.alive?(pid), do: {:ok, pid}, else: :not_found)

  @doc """
  Looks up the buffer visiting the same file as `path` via `Minga.Buffer.FileRegistry`.

  Both the buffer's registered path and `path` are resolved through every symlink, so a buffer opened as `lib/link.ex` is found by the path of the file the link names, and the reverse. A path whose tail does not exist yet resolves its existing parent directories. When several buffers visit the same file, every caller selects the same one (the lowest pid). Returns `:not_found` if no buffer visits the file.

  A buffer whose path went through a symlink, or did not fully exist, when it registered is resolved again at lookup, so it follows a link that was retargeted or a dangling link whose target was created since. Each lookup resolves only those buffers; a buffer whose path was already its real path is matched by its registered key.
  """
  @spec pid_for_file(String.t()) :: {:ok, pid()} | :not_found
  def pid_for_file(path) do
    key = file_key(path)
    direct = Minga.Buffer.FileRegistry |> Registry.match(key, nil) |> Enum.map(&elem(&1, 0))

    case Enum.filter(direct ++ resolved_indirect_pids(key), &Process.alive?/1) do
      [] -> :not_found
      pids -> {:ok, Enum.min(pids)}
    end
  end

  @doc """
  Returns the identity of the file at `path`: the key `Minga.Buffer.FileRegistry` registers a buffer visiting it under.

  The path is resolved through every symlink, and a missing tail keeps its names under its resolved parent, so every spelling of one file has one identity. It reads the file system; compute it once, off the render path.
  """
  @spec file_identity(String.t()) :: String.t()
  def file_identity(path) when is_binary(path), do: file_key(path)

  @doc """
  Returns the identities `buffer` is registered under for its file, or `[]` for a buffer with no file.

  It reads `Minga.Buffer.FileRegistry` only, without calling the buffer or the file system, so it is cheap enough for render. Compare with `file_identity/1`.
  """
  @spec file_identities(pid()) :: [String.t()]
  def file_identities(buffer) when is_pid(buffer),
    do: Registry.keys(Minga.Buffer.FileRegistry, buffer)

  # Buffers registered through a symlink or a missing tail store their path as
  # the registry value; their key may have changed on disk since registration.
  @spec resolved_indirect_pids(String.t()) :: [pid()]
  defp resolved_indirect_pids(key) do
    Minga.Buffer.FileRegistry
    |> Registry.select([{{:_, :"$1", :"$2"}, [{:is_binary, :"$2"}], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {pid, registered_path} ->
      if file_key(registered_path) == key, do: [pid], else: []
    end)
  end

  @doc "Returns the metadata needed to list this buffer, without reading its content."
  @spec listing_info(GenServer.server()) :: listing_info()
  def listing_info(server), do: GenServer.call(server, :listing_info)

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

  @doc "Sets the read-only flag at runtime (e.g. when the backing volume unmounts)."
  @spec set_read_only(GenServer.server(), boolean()) :: :ok
  def set_read_only(server, read_only?) do
    GenServer.call(server, {:set_read_only, read_only?})
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

  @doc """
  Appends text at the end of the buffer, then trims the oldest lines
  to stay within `max_lines` and `max_bytes` limits.

  Bypasses read-only. The text lands at the end wherever the cursor is. A cursor at the end follows the new text; any other cursor stays on its line, shifted up by the trimmed lines, or moves to `{0, 0}` when its line is trimmed. Each call at capacity still rebuilds the retained line index, so its cost grows with the retained line count.

  Designed for bounded log buffers like `*Messages*`.
  """
  @spec bounded_append(GenServer.server(), String.t(), pos_integer(), pos_integer()) :: :ok
  def bounded_append(server, text, max_lines, max_bytes)
      when is_binary(text) and max_lines > 0 and max_bytes > 0 do
    GenServer.call(server, {:bounded_append, text, max_lines, max_bytes})
  end

  alias Minga.Buffer.RenderSnapshot
  alias Minga.Buffer.RendererConsume
  alias Minga.Buffer.SyncSnapshot

  @doc "Returns bounded render metadata and only the requested lines."
  @spec render_snapshot(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          RenderSnapshot.t()
  def render_snapshot(server, first_line, count) when first_line >= 0 and count >= 0 do
    GenServer.call(server, {:render_snapshot, first_line, count})
  end

  @doc "Atomically consumes renderer changes and snapshots their affected line range."
  @spec renderer_consume(
          GenServer.server(),
          {non_neg_integer(), non_neg_integer()} | nil
        ) :: RendererConsume.t()
  def renderer_consume(server, prior_affected_range \\ nil) do
    GenServer.call(server, {:renderer_consume, prior_affected_range})
  end

  @doc "Fetches only a requested line range when the buffer is still at `expected_version`."
  @spec render_lines(GenServer.server(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, RenderSnapshot.t()} | :stale
  def render_lines(server, expected_version, first_line, count)
      when expected_version >= 0 and first_line >= 0 and count >= 0 do
    GenServer.call(server, {:render_lines, expected_version, first_line, count})
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

  @doc "Returns a byte-bounded line range, total lines, and mutation version atomically."
  @spec content_on_lines_with_version(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {String.t(), non_neg_integer(), pos_integer(), non_neg_integer(), boolean()}
  def content_on_lines_with_version(server, start_line, line_count, max_bytes)
      when start_line >= 0 and line_count >= 0 and max_bytes >= 0 do
    GenServer.call(
      server,
      {:content_on_lines_with_version, start_line, line_count, max_bytes}
    )
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

  @doc """
  Undoes your most recent edit group. Minga's edits are never undone this way.

  Returns `{:blocked, {:overlaps, minga_group}}`, with content and history unchanged, when a later Minga step rewrote text the group wrote or removed. Returns an error, with content and history unchanged, when the group no longer applies.
  """
  @spec undo(GenServer.server()) ::
          :ok | UndoHistory.blocked() | {:error, UndoPatch.apply_error()}
  def undo(server) do
    GenServer.call(server, :undo)
  end

  @doc "Redoes your most recently undone edit group. Returns the same outcomes as `undo/1`."
  @spec redo(GenServer.server()) ::
          :ok | UndoHistory.blocked() | {:error, UndoPatch.apply_error()}
  def redo(server) do
    GenServer.call(server, :redo)
  end

  @doc """
  Reverts every remaining step of the Minga task that edited this buffer most recently, keeping your edits. Returns how many steps it reverted.

  Returns `{:blocked, {:overlaps, minga_group}}`, with content and history unchanged, when a task that started later rewrote this task's text; see `Minga.Buffer.UndoHistory.reject_task/4`.
  """
  @spec undo_agent_session(GenServer.server()) ::
          {:ok, non_neg_integer()}
          | :empty
          | UndoHistory.blocked()
          | {:error, UndoPatch.apply_error()}
  def undo_agent_session(server) do
    GenServer.call(server, :undo_agent_session)
  end

  @doc """
  Returns who wrote the byte at `position`: `:you`, Minga in a task (`{:minga, task_id}`), Minga without a task (`{:minga, :untasked}`), or `:unattributed` for text that predates tracking.

  The column is a byte offset in the line, and a line's newline counts as its last byte. Returns `nil` for a position past the end of its line or of the buffer.
  """
  @spec author_at(GenServer.server(), Document.position()) :: Provenance.author() | nil
  def author_at(server, {line, column} = position) when line >= 0 and column >= 0 do
    GenServer.call(server, {:author_at, position})
  end

  @doc """
  Returns the authors of each line from `first_line`, at most `count` lines, in line order.

  Each line lists the distinct authors of its bytes, including its newline, in the order they first appear. Costs O(log n + k) for n authorship runs and k runs in the lines.
  """
  @spec line_authors(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          [[Provenance.author()]]
  def line_authors(server, first_line, count) when first_line >= 0 and count >= 0 do
    GenServer.call(server, {:line_authors, first_line, count})
  end

  @doc "Returns the remaining Minga steps of task `task_id` in this buffer, oldest first, with the ranges each touched as `{start, end}` positions."
  @spec minga_changes(GenServer.server(), Author.id()) :: [
          {Author.key(), [{Document.position(), Document.position()}]}
        ]
  def minga_changes(server, task_id) when is_binary(task_id) do
    GenServer.call(server, {:minga_changes, task_id})
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

  @doc "Removes every conceal range in a group atomically."
  @spec remove_conceal_group(GenServer.server(), atom()) :: :ok
  def remove_conceal_group(server, group) when is_atom(group) do
    GenServer.call(server, {:remove_conceal_group, group})
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
  @spec init(keyword()) :: {:ok, state(), {:continue, :take_kept_swap}} | {:stop, term()}
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

        document = Document.new(text)

        state = %BufState{
          document: document,
          undo_history: UndoHistory.new(document),
          file_path: path,
          filetype: filetype,
          options_server: options_server,
          storage: storage,
          local_persistence: LocalPersistence.new(opts, SystemFileSystem),
          buffer_type: buffer_type,
          save_state: BufState.loaded_save_state(path, {mtime, size}, text),
          name: Keyword.get(opts, :buffer_name),
          read_only: read_only,
          unlisted: Keyword.get(opts, :unlisted, false),
          persistent: Keyword.get(opts, :persistent, false),
          conflict_index: ConflictIndex.new(document),
          options: seed_options(options_server, filetype),
          explicit_options: MapSet.new(),
          swap: opts |> swap_options(storage) |> SwapState.new(),
          events_registry: Keyword.get(opts, :events_registry, Minga.Events.default_registry())
        }

        register_path(path)
        {:ok, state, {:continue, :take_kept_swap}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Runs before the buffer answers its first call, so whoever opened it sees the kept text.
  @impl true
  @spec handle_continue(:take_kept_swap, state()) :: {:noreply, state()}
  def handle_continue(:take_kept_swap, state), do: {:noreply, take_kept_swap(state)}

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:open, file_path}, _from, state) do
    case Persistence.read_content(state, file_path) do
      {:ok, text} when is_binary(text) ->
        if Unicode.valid_utf8?(text) do
          state = clear_swap(state)
          first_line = text |> String.split("\n", parts: 2) |> List.first("")
          filetype = Language.detect_filetype_from_content(file_path, first_line)

          {mtime, size} = Persistence.file_metadata(state, file_path)

          document = Document.new(text)

          new_state = %{
            BufState.open_saved_content(state, file_path, {mtime, size}, text)
            | document: document,
              filetype: filetype,
              options: reseed_options(state, filetype),
              decorations: Decorations.new(),
              undo_history: UndoHistory.reset(state.undo_history, document),
              change_log: ChangeLog.clear(state.change_log)
          }

          new_state = rebuild_conflict_index(new_state)

          unregister_path(state.file_path)
          register_path(file_path)

          broadcast_buffer_path_changed(state.file_path, new_state)

          {:reply, :ok, new_state}
        else
          {:reply, {:error, :binary_file}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:insert_text, _text, _source}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:insert_text, text, source}, _from, state) do
    result = Operation.insert_at_cursor(state.document, text)
    {:reply, :ok, record_operation(state, result, source)}
  end

  def handle_call(
        {:apply_edit, _from_pos, _to_pos, _text, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:apply_edit, from_pos, to_pos, new_text, source}, _from, state) do
    case Operation.replace_range(state.document, from_pos, to_pos, new_text) do
      {:error, _reason} = error -> {:reply, error, state}
      result -> {:reply, :ok, record_operation(state, result, source)}
    end
  end

  def handle_call(
        {:replace_lines, _start_line, _end_line, _text, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:replace_lines, start_line, end_line, new_text, source}, _from, state) do
    result = Operation.replace_lines(state.document, start_line, end_line, new_text)
    {:reply, :ok, record_operation(state, result, source)}
  end

  def handle_call(
        {:replace_byte_range_if_version, _version, _position, _length, _text, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(
        {:replace_byte_range_if_version, expected_version, position, length, text, source},
        _from,
        state
      ) do
    if BufState.version(state) == expected_version do
      case Operation.replace_byte_range(state.document, position, length, text) do
        :unchanged ->
          {:reply, {:ok, expected_version}, state}

        {:edited, new_doc, delta} ->
          undo_source = EditSource.to_undo_source(source)

          new_state =
            apply_operation(
              state,
              {:delta, new_doc, delta},
              source,
              {:force_delta, undo_source, :record_delta}
            )

          {:reply, {:ok, BufState.version(new_state)}, new_state}

        {:error, :invalid_range} = error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:apply_edits, _edits, _source}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:apply_edits, [], _source}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:apply_edits, edits, source}, _from, state) do
    case Operation.replace_ranges_with_patches(state.document, edits) do
      {:ok, doc, patches} ->
        undo_source = EditSource.to_undo_source(source)

        # Batch edits shift offsets between replacements, so consumers need a full content sync.
        state =
          apply_operation(state, {:batch, doc, patches}, source, {:batch, undo_source, :clear})

        {:reply, :ok, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:shift_lines, _start, _end, _shift, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:shift_lines, start_line, end_line, shift, source}, _from, state) do
    case Operation.shift_lines(state.document, start_line, end_line, shift) do
      :unchanged ->
        {:reply, :ok, state}

      {:shifted, new_doc, deltas, patch} ->
        {:reply, :ok, record_shift(state, new_doc, deltas, patch, source)}
    end
  end

  # ── Find and Replace ──

  def handle_call(
        {:find_and_replace, _old, _new, _boundary, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, "buffer is read-only"}, state}
  end

  def handle_call({:find_and_replace, old_text, new_text, boundary, source}, _from, state) do
    case Replace.apply_with_delta(state.document, old_text, new_text, boundary) do
      {:ok, new_doc, delta, msg} ->
        event_source = EditSource.from_undo_source(source)

        state =
          apply_operation(
            state,
            {:delta, new_doc, delta},
            event_source,
            {:force_delta, source, :clear}
          )

        {:reply, {:ok, msg}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(
        {:conditional_mutate, _expected, _operation, _identity, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:conditional_mutate, _expected, operation, _identity, _source}, _from, state)
      when operation == :delete or elem(operation, 0) == :create do
    {:reply, {:error, :unsupported_operation}, state}
  end

  def handle_call({:conditional_mutate, expected, operation, identity, source}, _from, state) do
    content = Document.content(state.document)
    generation = mutation_generation(identity, state)

    case FileMutation.prepare({:ok, content}, generation, identity, expected, operation) do
      {:ok, new_content} when is_binary(new_content) ->
        receipt = FileMutation.Receipt.committed({:ok, content}, new_content)

        {:reply, {:ok, receipt}, replace_content_by_changes(state, new_content, source)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:merge_fork, _ancestor, _fork_content, _staging, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:merge_fork, ancestor, fork_content, staging, source}, _from, state) do
    parent_content = Document.content(state.document)

    case Minga.Core.Diff.merge3(
           String.split(ancestor, "\n"),
           String.split(fork_content, "\n"),
           String.split(parent_content, "\n")
         ) do
      {:ok, lines} ->
        case stage_fork_content(staging, fork_content) do
          :ok ->
            merged = Enum.join(lines, "\n")
            new_state = replace_content_by_changes(state, merged, source)
            {:reply, {:ok, merged}, new_state}

          {:error, _} = error ->
            {:reply, error, state}

          {:conflict, _} = conflict ->
            {:reply, conflict, state}
        end

      {:conflict, _} = conflict ->
        {:reply, conflict, state}
    end
  end

  def handle_call({:install_fork_resolution, _, _, _, _, _}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(
        {:install_fork_resolution, version, merged, fork_content, staging, source},
        _from,
        state
      ) do
    with ^version <- BufState.version(state),
         :ok <- stage_fork_content(staging, fork_content) do
      {:reply, {:ok, merged}, replace_content_by_changes(state, merged, source)}
    else
      {:error, _} = error -> {:reply, error, state}
      {:conflict, _} = conflict -> {:reply, conflict, state}
      _version -> {:reply, {:error, :stale_parent}, state}
    end
  end

  def handle_call(
        {:publish_fork_deletion, _ancestor, _publication},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:publish_fork_deletion, ancestor, publication}, _from, state) do
    if Document.content(state.document) == ancestor do
      result =
        try do
          publication.()
        catch
          :exit, reason -> {:error, {:deletion_publication_failed, reason}}
        end

      {:reply, result, state}
    else
      {:reply, {:conflict, :parent_changed}, state}
    end
  end

  def handle_call(:delete_before, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(:delete_before, _from, state) do
    result = Operation.backspace(state.document)
    {:reply, :ok, record_operation(state, result, EditSource.user())}
  end

  def handle_call(:delete_at, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(:delete_at, _from, state) do
    result = Operation.delete_forward(state.document)
    {:reply, :ok, record_operation(state, result, EditSource.user())}
  end

  def handle_call({:move, direction}, _from, state) do
    new_buf = Cursor.move(state.document, direction)
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call({:move_to, pos}, _from, state) do
    new_buf = Cursor.place(state.document, pos)
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call({:move_to_if_version, expected_version, position}, _from, state) do
    case resolve_byte_position(state, expected_version, position) do
      {:ok, resolved} ->
        new_buf = Cursor.place(state.document, resolved)
        {:reply, {:ok, resolved}, %{state | document: new_buf}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve_position_if_version, expected_version, position}, _from, state) do
    {:reply, resolve_byte_position(state, expected_version, position), state}
  end

  def handle_call(
        {:move_to_utf16_if_version, expected_version, one_based_line, utf16_column},
        _from,
        state
      ) do
    move_to_utf16_reply(state, expected_version, one_based_line, utf16_column)
  end

  def handle_call(
        {:resolve_utf16_position_if_version, expected_version, one_based_line, utf16_column},
        _from,
        state
      ) do
    result = resolve_utf16_position(state, expected_version, one_based_line, utf16_column)
    {:reply, result, state}
  end

  def handle_call({:apply_motion, motion_fn}, _from, state) when is_function(motion_fn, 2) do
    cursor = Document.cursor(state.document)
    new_pos = motion_fn.(state.document, cursor)
    new_buf = Cursor.place(state.document, new_pos)
    {:reply, :ok, %{state | document: new_buf}}
  end

  def handle_call(:save, _from, state), do: save_current_reply(state)

  def handle_call({:save_if_version, expected_version, opts}, _from, state) do
    if BufState.version(state) == expected_version do
      case apply_save_transforms(state, opts) do
        {:ok, state} -> save_current_reply(state)
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :stale}, state}
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
        new_state = mark_saved(state, {new_mtime, new_size}, content)
        broadcast_buffer_saved(new_state, state.file_path)

        {:reply, :ok, new_state}

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
        state = clear_swap(state)
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
          BufState.accept_saved_content(state, {new_mtime, new_size}, text)
          | document: new_buf,
            filetype: filetype,
            options: reseed_options(state, filetype),
            undo_history: reload_history(state, new_buf),
            change_log: ChangeLog.clear(state.change_log),
            decorations: Decorations.new()
        }

        new_state = rebuild_conflict_index(new_state)

        defer_content_replaced(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prepare_save_as, file_path, overwrite}, _from, state) do
    target = Path.expand(file_path)
    {:reply, prepare_save_intent(state, target, overwrite), state}
  end

  def handle_call({:save_as, file_path}, _from, state) do
    save_as_reply(state, SaveIntent.overwrite(file_path, self(), state.file_path))
  end

  def handle_call({:save_as_if_version, expected_version, intent, opts}, _from, state) do
    case validate_save_intent(state, intent) do
      :ok -> save_as_if_current_version(state, expected_version, intent, opts)
      {:error, reason} -> {:reply, {:error, reason}, state}
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
      state = clear_swap(state)
      unregister_path(state.file_path)
      register_path(new_path)
      state = BufState.retarget_path(state, new_path)
      state = if BufState.dirty?(state), do: schedule_swap_write(state), else: state
      broadcast_buffer_path_changed(old_path, state)
      {:reply, :ok, state}
    end
  end

  def handle_call({:replace_content, _new_content, _source}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:replace_content, new_content, source}, _from, state) do
    {:reply, :ok, replace_content_state(state, new_content, source)}
  end

  def handle_call(
        {:adopt_recovered_text, _content, _swap_path},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:adopt_recovered_text, content, swap_path}, _from, state) do
    holds_text? = Document.content(state.document) == content

    cond do
      # The buffer has this text already, for example because it took its own kept swap when it started.
      # Unsaved, it must own the text on disk. Saved, nothing is unsaved and the swap can go.
      holds_text? and BufState.dirty?(state) ->
        :ok = take_over_recovered_swap(state, swap_path)
        {:reply, :ok, state}

      holds_text? ->
        :ok = remove_recovered_swap(state, swap_path, nil)
        {:reply, :ok, state}

      BufState.dirty?(state) ->
        {:reply, {:error, :modified}, state}

      true ->
        state = put_recovered_text(state, content)
        :ok = take_over_recovered_swap(state, swap_path)
        {:reply, :ok, state}
    end
  end

  def handle_call({:release_swap, swap_dir}, _from, state) do
    if SwapState.writes_into?(state.swap, swap_dir) do
      state = revoke_swap_writes(state)
      :ok = delete_swap_file(state)
      {:reply, :ok, %{state | swap: SwapState.release(state.swap)}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(
        {:replace_content_if_version, _expected_version, _new_content, _source},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call(
        {:replace_content_if_version, expected_version, new_content, source},
        _from,
        state
      ) do
    case BufState.version(state) do
      ^expected_version ->
        new_state = replace_content_at_version(state, new_content, source)
        {:reply, {:ok, BufState.version(new_state)}, new_state}

      _other_version ->
        {:reply, {:error, :stale}, state}
    end
  end

  # Force replace bypasses read_only. Used by panel buffers (file tree, agent)
  # that are read-only to the user but need programmatic content updates.
  def handle_call({:replace_generated_content, new_content}, _from, state) do
    state = clear_swap(state)
    new_buf = Document.new(new_content)

    new_state = %{
      BufState.record_clean_change(state)
      | document: new_buf,
        undo_history: UndoHistory.reset(state.undo_history, new_buf),
        change_log: ChangeLog.clear(state.change_log),
        decorations: Decorations.new()
    }

    new_state = rebuild_conflict_index(new_state)

    defer_content_replaced(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:accept_saved_content, new_content}, _from, state) do
    state = clear_swap(state)
    new_buf = Document.new(new_content)
    {mtime, size} = Persistence.file_metadata(state, state.file_path)

    new_state = %{
      BufState.accept_saved_content(state, {mtime, size}, new_content)
      | document: new_buf,
        undo_history: reload_history(state, new_buf),
        change_log: ChangeLog.clear(state.change_log),
        decorations: Decorations.new()
    }

    new_state = rebuild_conflict_index(new_state)

    defer_content_replaced(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:mark_saved_if_disk_matches, _from, %{file_path: nil} = state),
    do: {:reply, {:error, :no_file_path}, state}

  def handle_call(:mark_saved_if_disk_matches, _from, state) do
    content = Document.content(state.document)

    case Persistence.read_content(state, state.file_path) do
      {:ok, ^content} ->
        metadata = Persistence.file_metadata(state, state.file_path)
        {:reply, :ok, mark_saved(state, metadata, content)}

      {:ok, _other} ->
        {:reply, {:error, :content_differs}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  def handle_call(:content_with_version, _from, state) do
    {:reply, {Document.content(state.document), BufState.version(state)}, state}
  end

  def handle_call(:file_observation, _from, state) do
    {content, cursor} = Document.content_and_cursor(state.document)
    {:reply, {state.file_path, content, cursor, BufState.version(state)}, state}
  end

  def handle_call({:bounded_content_with_path, max_bytes}, _from, state) do
    if Document.content_byte_size(state.document) <= max_bytes do
      {:reply, {:ok, Document.content(state.document), state.file_path}, state}
    else
      {:reply, {:error, :too_large}, state}
    end
  end

  def handle_call({:content_prefix_with_version, max_bytes}, _from, state) do
    total = Document.content_byte_size(state.document)
    count = min(total, max_bytes)
    prefix = Document.slice_byte_range(state.document, 0, count)
    {:reply, {prefix, BufState.version(state), count == total}, state}
  end

  def handle_call(:conflicts, _from, state) do
    {:reply, ConflictIndex.entries(state.conflict_index), state}
  end

  def handle_call(:conflict_count, _from, state) do
    {:reply, ConflictIndex.count(state.conflict_index), state}
  end

  def handle_call(:conflict_snapshot, _from, state) do
    snapshot = {
      Document.content(state.document),
      Document.cursor(state.document),
      ConflictIndex.entries(state.conflict_index)
    }

    {:reply, snapshot, state}
  end

  def handle_call(:conflict_render_snapshot, _from, state) do
    {:reply, {BufState.version(state), ConflictIndex.entries(state.conflict_index)}, state}
  end

  def handle_call(:conflict_view, _from, state) do
    entries = Enum.map(ConflictIndex.entries(state.conflict_index), &conflict_region/1)

    view = %{
      version: BufState.version(state),
      cursor: Document.cursor(state.document),
      entries: entries
    }

    {:reply, view, state}
  end

  def handle_call(
        {:resolve_conflict, _version, _target, _choice},
        _from,
        %{read_only: true} = state
      ) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:resolve_conflict, expected_version, target, choice}, _from, state) do
    if BufState.version(state) == expected_version do
      case find_conflict(ConflictIndex.entries(state.conflict_index), target) do
        {%Entry{} = entry, anchor_line} ->
          document =
            state.document
            |> Document.content()
            |> MergeConflict.replace_region(entry, choice)
            |> Document.new()
            |> Document.move_to({anchor_line, 0})

          resolved = replace_content_document_state(state, document, :user)

          receipt = %{
            version: BufState.version(resolved),
            remaining: ConflictIndex.count(resolved.conflict_index)
          }

          {:reply, {:ok, receipt}, resolved}

        nil ->
          {:reply, {:error, :not_found}, state}
      end
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:inspection_snapshot, viewport_start, viewport_count}, _from, state) do
    inspection_snapshot_reply(state, viewport_start, viewport_count, :live)
  end

  def handle_call(
        {:inspection_snapshot, viewport_start, viewport_count, cursor_source},
        _from,
        state
      ) do
    inspection_snapshot_reply(state, viewport_start, viewport_count, cursor_source)
  end

  def handle_call(:inspection_marker, _from, state) do
    {:reply, {BufState.version(state), Document.cursor(state.document)}, state}
  end

  def handle_call({:byte_offset_for_line, line}, _from, state) do
    offset = Position.point_for(state.document, {line, 0})
    {:reply, offset, state}
  end

  def handle_call({:lines, start, count}, _from, state) do
    {:reply, Lines.slice(state.document, start, count), state}
  end

  def handle_call({:lines_at, line_numbers}, _from, state) do
    {:reply, Lines.fetch_many(state.document, line_numbers), state}
  end

  def handle_call(:cursor, _from, state) do
    {:reply, Document.cursor(state.document), state}
  end

  def handle_call(:cursor_context, _from, state) do
    context =
      CursorContext.new(state.document, BufState.version(state), state.file_path, state.filetype)

    {:reply, context, state}
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

  def handle_call(:content_byte_size, _from, state) do
    {:reply, Document.content_byte_size(state.document), state}
  end

  def handle_call(:dirty?, _from, state) do
    {:reply, BufState.dirty?(state), state}
  end

  def handle_call(
        {:confirm_scratch_save, version},
        _from,
        %{file_path: nil, buffer_type: :nofile} = state
      ) do
    if BufState.version(state) == version do
      content = Document.content(state.document)
      {:reply, :ok, BufState.mark_saved(state, {nil, nil}, content)}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:confirm_scratch_save, _version}, _from, state), do: {:reply, :stale, state}

  def handle_call(:consume_edit_deltas, _from, state) do
    {edits, change_log} = ChangeLog.drain_pending_changes(state.change_log)
    {:reply, edits, %{state | change_log: change_log}}
  end

  def handle_call({:consume_edit_deltas, consumer_id}, _from, state) do
    {result, change_log} = ChangeLog.take_unseen_changes(state.change_log, consumer_id)
    {:reply, result, %{state | change_log: change_log}}
  end

  def handle_call({:renderer_consume, prior_affected_range}, _from, state) do
    {changes, change_log} = ChangeLog.take_unseen_changes(state.change_log, :renderer)
    state = %{state | change_log: change_log}

    result = %RendererConsume{
      version: BufState.version(state),
      line_count: Document.line_count(state.document),
      change_sequence: ChangeLog.sequence(change_log),
      changes: changes,
      snapshot: renderer_changed_snapshot(state, changes, prior_affected_range)
    }

    {:reply, result, state}
  end

  def handle_call({:changes_since, sequence}, _from, state) do
    {:reply, ChangeLog.changes_since(state.change_log, sequence), state}
  end

  def handle_call(:version, _from, state) do
    {:reply, BufState.version(state), state}
  end

  def handle_call(:listing_info, _from, state) do
    info = %{
      name: state.name,
      file_path: state.file_path,
      filetype: state.filetype,
      unlisted: state.unlisted,
      read_only: state.read_only,
      dirty: BufState.dirty?(state)
    }

    {:reply, info, state}
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

  def handle_call({:set_read_only, read_only?}, _from, state) do
    {:reply, :ok, %{state | read_only: read_only?}}
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
    appended = {byte_size(content), "", text}

    new_state =
      state
      |> install_document(new_buf, &UndoHistory.record_untracked(&1, [appended]))
      |> rebuild_conflict_index()

    {:reply, :ok, new_state}
  end

  def handle_call({:bounded_append, text, max_lines, max_bytes}, _from, state) do
    doc = state.document
    appended = {Document.cursor_offset(doc), "", text}

    # Append at the end even when the reader moved the cursor up (`gg` in *Messages*).
    # The front trim below then never removes the new entry.
    doc = Document.append_text(doc, text)

    total_lines = Document.line_count(doc)
    total_bytes = Document.content_byte_size(doc)

    lines_to_drop = max(0, total_lines - max_lines)

    lines_to_drop =
      if total_bytes > max_bytes do
        max(lines_to_drop, lines_for_byte_target(doc, total_bytes - max_bytes))
      else
        lines_to_drop
      end

    {doc, changes} =
      if lines_to_drop > 0 do
        trimmed = Document.trim_leading_lines(doc, lines_to_drop)
        dropped = total_bytes - Document.content_byte_size(trimmed)
        {trimmed, [appended, {0, Document.slice_byte_range(doc, 0, dropped), ""}]}
      else
        {doc, [appended]}
      end

    new_state =
      state
      |> install_document(doc, &UndoHistory.record_untracked(&1, changes))
      |> rebuild_conflict_index()

    {:reply, :ok, new_state}
  end

  def handle_call({:render_snapshot, first_line, count}, _from, state) do
    {:reply, bounded_render_snapshot(state, first_line, count), state}
  end

  def handle_call({:render_lines, expected_version, first_line, count}, _from, state) do
    if BufState.version(state) == expected_version do
      {:reply, {:ok, bounded_render_snapshot(state, first_line, count)}, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call(:sync_revision, _from, state) do
    {:reply, {BufState.version(state), ChangeLog.sequence(state.change_log)}, state}
  end

  def handle_call({:delete_range, _from_pos, _to_pos}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:delete_range, from_pos, to_pos}, _from, state) do
    result = Operation.delete_range(state.document, from_pos, to_pos)
    {:reply, :ok, record_operation(state, result, EditSource.user())}
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

  def handle_call(
        {:content_on_lines_with_version, start_line, line_count, max_bytes},
        _from,
        state
      ) do
    {content, selected_count, total, complete?} =
      Lines.bounded_contents(state.document, start_line, line_count, max_bytes)

    {:reply, {content, selected_count, total, BufState.version(state), complete?}, state}
  end

  def handle_call({:delete_lines, _start_line, _end_line}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:delete_lines, start_line, end_line}, _from, state) do
    result = Operation.delete_lines(state.document, start_line, end_line)
    {:reply, :ok, record_operation(state, result, EditSource.user())}
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
    state =
      apply_operation(state, {:full, new_buf}, EditSource.user(), {:full, :user, :clear})

    {:reply, :ok, state}
  end

  def handle_call({:clear_line, _line}, _from, %{read_only: true} = state) do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:clear_line, line}, _from, state) do
    case Operation.clear_line(state.document, line) do
      :unchanged ->
        {:reply, {:ok, ""}, state}

      {:edited, yanked, new_doc, delta} ->
        state = record_operation(state, {:edited, new_doc, delta}, EditSource.user())

        {:reply, {:ok, yanked}, state}
    end
  end

  def handle_call(:undo, _from, state) do
    state = with_history_in_step(state)

    case UndoHistory.undo(state.undo_history, BufState.version(state), state.document) do
      :empty ->
        {:reply, :ok, state}

      {:blocked, _overlap} = blocked ->
        {:reply, blocked, state}

      {:error, reason} = error ->
        log_history_failure(:undo, reason)
        {:reply, error, state}

      {:ok, restore, undo_history} ->
        log_undo_source(:undo, restore.source)
        {:reply, :ok, install_restore(state, restore, undo_history)}
    end
  end

  def handle_call(:redo, _from, state) do
    state = with_history_in_step(state)

    case UndoHistory.redo(state.undo_history, BufState.version(state), state.document) do
      :empty ->
        {:reply, :ok, state}

      {:blocked, _overlap} = blocked ->
        {:reply, blocked, state}

      {:error, reason} = error ->
        log_history_failure(:redo, reason)
        {:reply, error, state}

      {:ok, restore, undo_history} ->
        log_undo_source(:redo, restore.source)
        {:reply, :ok, install_restore(state, restore, undo_history)}
    end
  end

  def handle_call(:undo_agent_session, _from, state) do
    state = with_history_in_step(state)

    case UndoHistory.undo_agent_session(
           state.undo_history,
           BufState.version(state),
           state.document
         ) do
      :empty ->
        {:reply, :empty, state}

      {:blocked, _overlap} = blocked ->
        {:reply, blocked, state}

      {:error, reason} = error ->
        log_history_failure(:undo_agent_session, reason)
        {:reply, error, state}

      {:ok, restore, undo_history, count} ->
        Minga.Log.debug(:editor, "Undo agent session: reverted #{count} agent steps")
        {:reply, {:ok, count}, install_restore(state, restore, undo_history)}
    end
  end

  def handle_call({:author_at, {line, column}}, _from, state) do
    document = state.document
    line_count = Document.line_count(document)

    author =
      if line < line_count and
           Lines.start_of(document, line) + column < line_end(document, line, line_count),
         do:
           Provenance.author_at(
             UndoHistory.provenance(state.undo_history),
             Lines.start_of(document, line) + column
           )

    {:reply, author, state}
  end

  def handle_call({:line_authors, first_line, count}, _from, state) do
    {:reply, line_authors_in(state, first_line, count), state}
  end

  def handle_call({:minga_changes, task_id}, _from, state) do
    changes =
      for {key, ranges} <- UndoHistory.minga_changes(state.undo_history, task_id) do
        {key,
         Enum.map(ranges, fn {from, to} ->
           {Position.from_point(state.document, from), Position.from_point(state.document, to)}
         end)}
      end

    {:reply, changes, state}
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

  def handle_call({:remove_conceal_group, group}, _from, state) do
    decs = Decorations.remove_conceal_group(state.decorations, group)
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
        undo_history: UndoHistory.reset(state.undo_history, new_doc),
        change_log: ChangeLog.clear(state.change_log),
        decorations: new_decs
    }

    new_state = rebuild_conflict_index(new_state)

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

  @spec move_to_utf16_reply(state(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          {:reply,
           {:ok, Document.position()}
           | {:error, :stale | :line_out_of_range | :column_out_of_range | :column_not_boundary},
           state()}
  defp move_to_utf16_reply(state, expected_version, one_based_line, utf16_column) do
    case resolve_utf16_position(state, expected_version, one_based_line, utf16_column) do
      {:ok, position} ->
        document = Cursor.place(state.document, position)
        {:reply, {:ok, Document.cursor(document)}, %{state | document: document}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec resolve_byte_position(state(), non_neg_integer(), Document.position()) ::
          {:ok, Document.position()} | {:error, :stale | :position_out_of_range}
  defp resolve_byte_position(state, expected_version, {line, column}) do
    resolve_byte_position_for(state, BufState.version(state), expected_version, line, column)
  end

  @spec resolve_byte_position_for(
          state(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, Document.position()} | {:error, :stale | :position_out_of_range}
  defp resolve_byte_position_for(_state, actual_version, expected_version, _line, _column)
       when actual_version != expected_version,
       do: {:error, :stale}

  defp resolve_byte_position_for(state, _actual_version, _expected_version, line, column) do
    case Document.line_at(state.document, line) do
      text when is_binary(text) ->
        if column <= byte_size(text) and Cursor.caret_boundary?(text, column),
          do: {:ok, {line, column}},
          else: {:error, :position_out_of_range}

      nil ->
        {:error, :position_out_of_range}
    end
  end

  @spec resolve_utf16_position(
          state(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, Document.position()}
          | {:error, :stale | :line_out_of_range | :column_out_of_range | :column_not_boundary}
  defp resolve_utf16_position(state, expected_version, line, column) do
    resolve_utf16_position_for(
      {state, BufState.version(state), Document.line_count(state.document)},
      expected_version,
      line,
      column
    )
  end

  @spec resolve_utf16_position_for(
          {state(), non_neg_integer(), pos_integer()},
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, Document.position()}
          | {:error, :stale | :line_out_of_range | :column_out_of_range | :column_not_boundary}
  defp resolve_utf16_position_for(
         {_state, actual_version, _line_count},
         expected_version,
         _line,
         _column
       )
       when expected_version != actual_version,
       do: {:error, :stale}

  defp resolve_utf16_position_for(
         {_state, _actual_version, line_count},
         _expected_version,
         line,
         _column
       )
       when line > line_count,
       do: {:error, :line_out_of_range}

  defp resolve_utf16_position_for(
         {state, _actual_version, _line_count},
         _version,
         one_based_line,
         utf16_column
       ) do
    zero_based_line = one_based_line - 1
    line_text = Document.line_at(state.document, zero_based_line)

    case PositionEncoding.exact_byte_column(line_text, utf16_column, :utf16) do
      {:ok, byte_column} -> exact_caret_position(line_text, zero_based_line, byte_column)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec exact_caret_position(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Document.position()} | {:error, :column_not_boundary}
  defp exact_caret_position(line_text, line, column) do
    if Cursor.caret_boundary?(line_text, column),
      do: {:ok, {line, column}},
      else: {:error, :column_not_boundary}
  end

  @spec prepare_save_intent(state(), String.t(), boolean()) ::
          {:ok, SaveIntent.t()} | {:error, term()}
  defp prepare_save_intent(%{file_path: file_path} = state, target, overwrite)
       when is_binary(file_path) do
    if Persistence.same_file?(state, file_path, target) do
      {:ok, SaveIntent.current_file(target, file_path, overwrite, self())}
    else
      prepare_other_save_intent(state, target, overwrite)
    end
  end

  defp prepare_save_intent(state, target, overwrite) do
    prepare_other_save_intent(state, target, overwrite)
  end

  @spec prepare_other_save_intent(state(), String.t(), boolean()) ::
          {:ok, SaveIntent.t()} | {:error, term()}
  defp prepare_other_save_intent(state, target, true) do
    {:ok, SaveIntent.overwrite(target, self(), state.file_path)}
  end

  defp prepare_other_save_intent(state, target, false) do
    case Persistence.file_info(state, target) do
      {:ok, _stat} -> {:error, :file_exists}
      {:error, :enoent} -> {:ok, SaveIntent.absent(target, self(), state.file_path)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec save_as_reply(state(), SaveIntent.t()) :: {:reply, term(), state()}
  defp save_as_reply(state, %SaveIntent{} = intent) do
    if origin_path_matches?(state, intent.origin_path) do
      save_as_with_matching_origin(state, intent)
    else
      {:reply, {:error, :stale}, state}
    end
  end

  @spec save_as_with_matching_origin(state(), SaveIntent.t()) :: {:reply, term(), state()}
  defp save_as_with_matching_origin(state, %SaveIntent{expectation: :current_file} = intent) do
    if Persistence.same_file?(state, state.file_path, intent.target) do
      save_current_intent_reply(state, intent)
    else
      {:reply, {:error, :stale}, state}
    end
  end

  defp save_as_with_matching_origin(state, %SaveIntent{} = intent) do
    content = Document.content(state.document)

    case Persistence.write_content(state, intent.target, content, write_policy(intent)) do
      :ok ->
        {new_mtime, new_size} = Persistence.file_metadata(state, intent.target)
        state = clear_swap(state)
        unregister_path(state.file_path)
        register_path(intent.target)

        first_line = content |> String.split("\n", parts: 2) |> List.first("")
        filetype = Language.detect_filetype_from_content(intent.target, first_line)

        new_state = BufState.adopt_saved_path(state, intent.target, filetype)
        new_state = %{new_state | options: reseed_options(new_state, filetype)}
        new_state = mark_saved(new_state, {new_mtime, new_size}, content)
        broadcast_buffer_saved(new_state, intent.target)
        broadcast_buffer_path_changed(state.file_path, new_state)

        {:reply, :ok, new_state}

      {:error, :eexist} ->
        {:reply, {:error, :file_exists}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec save_current_intent_reply(state(), SaveIntent.t()) :: {:reply, term(), state()}
  defp save_current_intent_reply(state, %SaveIntent{overwrite: true, target: target}) do
    content = Document.content(state.document)

    case Persistence.write_content(state, target, content) do
      :ok ->
        {new_mtime, new_size} = Persistence.file_metadata(state, target)
        new_state = mark_saved(state, {new_mtime, new_size}, content)
        broadcast_buffer_saved(new_state, target)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp save_current_intent_reply(state, %SaveIntent{overwrite: false}) do
    save_current_reply(state)
  end

  @spec write_policy(SaveIntent.t()) :: Persistence.write_policy()
  defp write_policy(%SaveIntent{overwrite: false, expectation: :absent}), do: :exclusive_create
  defp write_policy(%SaveIntent{overwrite: true, expectation: :any}), do: :replace

  @spec validate_save_intent(state(), SaveIntent.t()) ::
          :ok | {:error, :invalid_save_intent | :stale}
  defp validate_save_intent(state, intent) do
    with :ok <- SaveIntent.validate(intent, self()) do
      if origin_path_matches?(state, intent.origin_path) and
           target_matches_expectation?(state, intent) do
        :ok
      else
        {:error, :stale}
      end
    end
  end

  @spec target_matches_expectation?(state(), SaveIntent.t()) :: boolean()
  defp target_matches_expectation?(state, %SaveIntent{expectation: :current_file, target: target}) do
    Persistence.same_file?(state, state.file_path, target)
  end

  defp target_matches_expectation?(_state, %SaveIntent{}), do: true

  @spec origin_path_matches?(state(), SaveIntent.origin_path()) :: boolean()
  defp origin_path_matches?(%{file_path: nil}, nil), do: true
  defp origin_path_matches?(%{file_path: nil}, _origin_path), do: false
  defp origin_path_matches?(%{file_path: _current_path}, nil), do: false

  defp origin_path_matches?(%{file_path: current_path} = state, origin_path) do
    Persistence.same_file?(state, current_path, origin_path)
  end

  @spec save_as_if_current_version(state(), non_neg_integer(), SaveIntent.t(), keyword()) ::
          {:reply, term(), state()}
  defp save_as_if_current_version(state, expected_version, intent, opts) do
    if BufState.version(state) == expected_version do
      case apply_save_transforms(state, opts) do
        {:ok, state} -> save_as_reply(state, intent)
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :stale}, state}
    end
  end

  defp apply_save_transforms(state, opts) do
    trim = Keyword.get(opts, :trim_trailing_whitespace, false)
    final_newline = Keyword.get(opts, :insert_final_newline, false)

    if trim or final_newline do
      content = Document.content(state.document)
      transformed = Minga.Editing.apply_save_transforms(content, trim, final_newline)

      cond do
        transformed == content -> {:ok, state}
        state.read_only -> {:error, :read_only}
        true -> {:ok, replace_content_state(state, transformed, :user)}
      end
    else
      {:ok, state}
    end
  end

  defp save_current_reply(%{buffer_type: bt} = state) when bt in [:nofile, :nowrite] do
    {:reply, {:error, :buffer_not_saveable}, state}
  end

  defp save_current_reply(%{file_path: nil} = state) do
    {:reply, {:error, :no_file_path}, state}
  end

  defp save_current_reply(state) do
    {disk_mtime, disk_size} = Persistence.file_metadata(state, state.file_path)

    if Persistence.changed_since_saved?(state, disk_mtime, disk_size) do
      {:reply, {:error, :file_changed}, state}
    else
      content = Document.content(state.document)

      case Persistence.write_content(state, state.file_path, content) do
        :ok ->
          {new_mtime, new_size} = Persistence.file_metadata(state, state.file_path)
          new_state = mark_saved(state, {new_mtime, new_size}, content)
          broadcast_buffer_saved(new_state, state.file_path)

          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  # ── Deferred broadcasts (avoid deadlock in handle_call) ──

  @impl true
  def handle_info({:request_sync_snapshot, cursor, reply_to, token}, state) do
    version = BufState.version(state)
    sequence = ChangeLog.sequence(state.change_log)
    changes = sync_snapshot_changes(state, cursor)

    send(
      reply_to,
      {:buffer_sync_snapshot,
       %SyncSnapshot{
         buffer: self(),
         token: token,
         version: version,
         sequence: sequence,
         changes: changes
       }}
    )

    {:noreply, state}
  end

  def handle_info({:deferred_broadcast, topic, payload}, state) do
    Events.broadcast(topic, payload, state.events_registry)
    {:noreply, state}
  end

  def handle_info({:write_swap, token}, state) when is_reference(token) do
    case SwapState.consume_timer(state.swap, token) do
      {:ok, swap} -> {:noreply, admit_current_swap(%{state | swap: swap})}
      :stale -> {:noreply, state}
    end
  end

  def handle_info(:write_swap, state) do
    state = cancel_swap_timer(state)
    {:noreply, admit_current_swap(state)}
  end

  def handle_info({:swap_prepared, worker, generation, result}, state)
      when is_pid(worker) and is_integer(generation) do
    {:noreply, handle_prepared_swap(state, worker, generation, result)}
  end

  def handle_info({:DOWN, monitor, :process, worker, reason}, state)
      when is_reference(monitor) and is_pid(worker) do
    case SwapState.complete_monitor(state.swap, worker, monitor) do
      {:ok, _generation, pending, swap} ->
        maybe_log_swap_worker_failure(state, reason)
        {:noreply, start_pending_swap(%{state | swap: swap}, pending)}

      :unknown ->
        {:noreply, state}
    end
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
  def terminate(reason, state) do
    state = state |> cancel_auto_save_timer() |> revoke_swap_writes()

    if deliberate_stop?(reason) do
      # A closed buffer leaves nothing to recover.
      delete_swap_file(state)
    else
      keep_swap_after_crash(state, reason)
    end

    :ok
  end

  # `GenServer.stop/1`, a supervisor shutdown and a `{:stop, ...}` return are deliberate. Any other reason is a crash.
  @spec deliberate_stop?(term()) :: boolean()
  defp deliberate_stop?(:normal), do: true
  defp deliberate_stop?(:shutdown), do: true
  defp deliberate_stop?({:shutdown, _detail}), do: true
  defp deliberate_stop?(_reason), do: false

  # A crash must not cost the user their unsaved text, so the swap file stays on disk.
  # The swap on disk can be one debounce old, or missing, so the current text is written first.
  # The log names both paths, and `:buffer_crashed` tells the editor which swap to recover.
  @spec keep_swap_after_crash(state(), term()) :: :ok
  defp keep_swap_after_crash(%{buffer_type: :file, file_path: path} = state, reason)
       when is_binary(path) do
    outcome = flush_swap_for_crash(state, path)

    Minga.Log.error(
      :editor,
      "Buffer for #{path} crashed (#{crash_summary(reason)}). #{crash_outcome_text(outcome)}"
    )

    case outcome do
      {:kept, swap_path} ->
        Events.broadcast(
          :buffer_crashed,
          %Events.BufferCrashedEvent{buffer: self(), path: path, swap_path: swap_path},
          state.events_registry
        )

      _nothing_to_recover ->
        :ok
    end
  end

  defp keep_swap_after_crash(_state, _reason), do: :ok

  @spec crash_outcome_text({:kept, String.t()} | :clean | :not_kept) :: String.t()
  defp crash_outcome_text({:kept, swap_path}), do: "Its unsaved text is kept in #{swap_path}."
  defp crash_outcome_text(:clean), do: "It had no unsaved text."
  defp crash_outcome_text(:not_kept), do: "Its unsaved text could not be kept."

  # `:clean` means there was nothing to keep. `:not_kept` means unsaved text existed and no swap file holds it:
  # the buffer has no swap directory, or the write failed and no earlier swap is on disk.
  @spec flush_swap_for_crash(state(), String.t()) :: {:kept, String.t()} | :clean | :not_kept
  defp flush_swap_for_crash(state, path) do
    cond do
      not BufState.dirty?(state) -> :clean
      not SwapState.configured?(state.swap) -> :not_kept
      true -> write_crash_swap(state, path)
    end
  end

  @spec write_crash_swap(state(), String.t()) :: {:kept, String.t()} | :not_kept
  defp write_crash_swap(state, path) do
    opts = SwapState.backend_options(state.swap, state.swap.generation)
    swap_path = Minga.Session.Swap.swap_path(path, opts)

    case write_swap_now(state, path, opts) do
      :ok ->
        {:kept, swap_path}

      {:error, reason} ->
        # A failed write leaves the last published swap in place: older text, but still unsaved text.
        log_swap_failure(state, {:crash_flush_failed, reason})
        if File.exists?(swap_path), do: {:kept, swap_path}, else: :not_kept
    end
  end

  # Runs in the dying buffer process.
  # Every failure, including a document that cannot be read, becomes an error value.
  # It cannot replace the original crash.
  @spec write_swap_now(state(), String.t(), keyword()) :: :ok | {:error, term()}
  defp write_swap_now(state, path, opts) do
    backend = SwapState.backend(state.swap)

    swap_backend_call(fn ->
      with {:ok, prepared} <- backend.prepare(path, Document.content(state.document), opts) do
        backend.publish(prepared)
      end
    end)
  end

  # Every local buffer gets the VM's swap directory unless its opener chose one, so a buffer that gets its file
  # later (`:w name` in a new buffer) is covered too. Only a file buffer with a path ever writes a swap.
  # A remote file is not covered: its swap would name a path that means something else on this machine.
  @spec swap_options(keyword(), BufState.storage()) :: keyword()
  defp swap_options(opts, :local) do
    opts
    |> Keyword.put_new(:swap_backend, Minga.Session.Swap)
    |> Keyword.put_new_lazy(:swap_dir, &Minga.Session.buffer_swap_dir/0)
  end

  defp swap_options(opts, _remote), do: Keyword.put_new(opts, :swap_backend, Minga.Session.Swap)

  # A buffer of this run that crashed left its unsaved text at the swap path this buffer is about to use.
  # So did an earlier run that had this run's OS process id, for a file the startup recovery did not cover.
  # Without this step the next edit would overwrite that text, and a save, a close or a quit would delete it.
  # So a buffer that starts on such a path takes the text and is the owner of that swap file from then on.
  @spec take_kept_swap(state()) :: state()
  defp take_kept_swap(%{buffer_type: :file, file_path: path, read_only: false} = state)
       when is_binary(path) do
    if SwapState.configured?(state.swap) do
      swap_path = Minga.Session.Swap.swap_path(path, SwapState.backend_options(state.swap, 0))

      case Minga.Session.Swap.read(swap_path) do
        {:ok, %{path: ^path} = kept, content} -> take_kept_text(state, content, kept)
        _no_kept_swap -> state
      end
    else
      state
    end
  end

  defp take_kept_swap(state), do: state

  @spec take_kept_text(state(), binary(), Minga.Session.Swap.metadata()) :: state()
  defp take_kept_text(state, content, %{swap_path: swap_path} = kept) do
    if Document.content(state.document) == content do
      :ok = remove_recovered_swap(state, swap_path, nil)
      state
    else
      Minga.Log.info(
        :editor,
        "Opened #{state.file_path} with the unsaved text that was kept for it in #{swap_path}"
      )

      :ok = warn_if_file_is_newer(state, kept)
      put_recovered_text(state, content)
    end
  end

  # The swap name carries the OS process id, and a later run can get the id of a run that crashed.
  # Its leftover swap then looks like this run's own. The text is still shown, never saved unasked,
  # and the log says that the file is newer, so the user knows which of the two to keep.
  @spec warn_if_file_is_newer(state(), Minga.Session.Swap.metadata()) :: :ok
  defp warn_if_file_is_newer(%{file_path: path}, %{mtime: kept_at}) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: saved_at}} when saved_at > kept_at ->
        Minga.Log.warning(
          :editor,
          "#{path} was saved after that unsaved text was kept: undo brings back the file's text"
        )

      _older_or_missing ->
        :ok
    end
  end

  # Recovered text is shown, never saved on its own. Auto-save would write it over the file about a second
  # after it appears, before anyone has looked at it, and over a change the file got in the meantime.
  # The next edit or an explicit save is the user's decision, and auto-save resumes from there.
  @spec put_recovered_text(state(), binary()) :: state()
  defp put_recovered_text(state, content) do
    state |> replace_content_state(content, :recovery) |> cancel_auto_save_timer()
  end

  # Makes this buffer's own swap file hold the recovered text before the swap it came from is removed.
  # The text is on disk at every moment: in the old swap, in both, or in the new one.
  @spec take_over_recovered_swap(state(), String.t()) :: :ok
  defp take_over_recovered_swap(%{file_path: path} = state, recovered_from)
       when is_binary(path) do
    if SwapState.configured?(state.swap) do
      opts = SwapState.backend_options(state.swap, state.swap.generation)

      case write_swap_now(state, path, opts) do
        :ok ->
          remove_recovered_swap(state, recovered_from, Minga.Session.Swap.swap_path(path, opts))

        {:error, reason} ->
          log_swap_failure(state, {:recovery_takeover_failed, reason})
      end
    else
      # Without a swap directory nothing else would remove the old swap.
      remove_recovered_swap(state, recovered_from, nil)
    end
  end

  defp take_over_recovered_swap(_state, _recovered_from), do: :ok

  @spec remove_recovered_swap(state(), String.t(), String.t() | nil) :: :ok
  defp remove_recovered_swap(_state, own_swap, own_swap), do: :ok

  defp remove_recovered_swap(state, recovered_from, _own_swap) do
    case File.rm(recovered_from) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> log_swap_failure(state, {:recovered_swap_not_removed, reason})
    end
  end

  # A raising callback exits with `{error, stacktrace}`.
  # Its message reads better than the raw term, and the stacktrace is in the crash report.
  @spec crash_summary(term()) :: String.t()
  defp crash_summary({error, stacktrace}) when is_list(stacktrace) do
    :error |> Exception.normalize(error, stacktrace) |> Exception.message()
  rescue
    _not_an_error -> inspect(error, limit: 5, printable_limit: 200)
  end

  defp crash_summary(reason), do: inspect(reason, limit: 5, printable_limit: 200)

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

    {key, indirection} = file_registration(abs_path)
    {:ok, _} = Registry.register(Minga.Buffer.FileRegistry, key, indirection)
    :ok
  end

  # A path that is already its real path registers `nil`; any other path
  # registers itself so `pid_for_file/1` resolves it again at lookup.
  @spec file_registration(String.t()) :: {String.t(), String.t() | nil}
  defp file_registration(abs_path) do
    case Minga.Project.Root.canonical_path(abs_path) do
      {:ok, ^abs_path} -> {abs_path, nil}
      {:ok, real_path} -> {real_path, abs_path}
      {:error, _reason} -> {missing_tail_file_key(abs_path), abs_path}
    end
  end

  # The file key is computed when the path is registered, so it may differ from
  # a key computed now if a symlink changed since; remove every key this buffer
  # holds instead of recomputing the old one.
  @spec unregister_path(String.t() | nil) :: :ok
  defp unregister_path(nil), do: :ok

  defp unregister_path(path) do
    abs_path = Path.expand(path)
    Registry.unregister(Minga.Buffer.Registry, abs_path)

    Minga.Buffer.FileRegistry
    |> Registry.keys(self())
    |> Enum.each(&Registry.unregister(Minga.Buffer.FileRegistry, &1))
  end

  # Names the file a path visits: the path with every symlink followed. A
  # missing tail (a new file not yet saved) keeps its names under the resolved
  # existing parent, so the key does not change when the file is created.
  @spec file_key(String.t()) :: String.t()
  defp file_key(path) do
    expanded = Path.expand(path)

    case Minga.Project.Root.canonical_path(expanded) do
      {:ok, real_path} -> real_path
      {:error, _reason} -> missing_tail_file_key(expanded)
    end
  end

  @spec missing_tail_file_key(String.t()) :: String.t()
  defp missing_tail_file_key(path) do
    case Path.dirname(path) do
      ^path -> path
      parent -> Path.join(file_key(parent), Path.basename(path))
    end
  end

  # ── Private ──

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
  defp defer_buffer_changed(state, delta, source),
    do: defer_buffer_changed(state, delta, source, ChangeLog.sequence(state.change_log))

  @spec defer_buffer_changed(
          state(),
          EditDelta.t() | nil,
          EditSource.t(),
          ChangeLog.sequence()
        ) :: :ok
  defp defer_buffer_changed(state, delta, source, sequence) do
    send(
      self(),
      {:deferred_broadcast, :buffer_changed,
       %Events.BufferChangedEvent{
         buffer: self(),
         delta: delta,
         source: source,
         version: BufState.version(state),
         sequence: sequence
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

  @spec stage_fork_content(
          (String.t() -> :ok | {:conflict, term()} | {:error, term()}) | nil,
          String.t()
        ) :: :ok | {:conflict, term()} | {:error, term()}
  defp stage_fork_content(nil, _fork_content), do: :ok

  defp stage_fork_content(staging, fork_content) do
    staging.(fork_content)
  catch
    :exit, reason -> {:error, {:fork_staging_failed, reason}}
  end

  @spec mutation_generation(FileMutation.identity(), state()) :: non_neg_integer() | nil
  defp mutation_generation({:project_view, _source_id}, _state), do: nil
  defp mutation_generation(_identity, state), do: BufState.version(state)

  @spec replace_content_state(state(), String.t(), BufState.edit_source()) :: state()
  defp replace_content_state(state, new_content, source) do
    replace_content_document_state(state, Document.new(new_content), source)
  end

  @spec replace_content_preserving_cursor_state(state(), String.t(), BufState.edit_source()) ::
          state()
  defp replace_content_preserving_cursor_state(state, new_content, source) do
    new_document =
      new_content
      |> Document.new()
      |> Document.move_to(Document.cursor(state.document))

    replace_content_document_state(state, new_document, source)
  end

  # An agent replacement records its changed regions; any other keeps the whole-buffer patch.
  @spec replace_content_at_version(state(), String.t(), BufState.edit_source()) :: state()
  defp replace_content_at_version(state, new_content, source)
       when source == :agent or Author.is_key(source),
       do: replace_content_by_changes(state, new_content, source)

  defp replace_content_at_version(state, new_content, source),
    do: replace_content_preserving_cursor_state(state, new_content, source)

  # Records an agent's whole-content replacement as one undo entry with one patch per changed
  # region, so each change keeps its author and step. The document, cursor, decorations, dirty
  # state, version and change event match `replace_content_preserving_cursor_state/3`, and an
  # unchanged replacement still records one empty patch, as that path does.
  @spec replace_content_by_changes(state(), String.t(), BufState.edit_source()) :: state()
  defp replace_content_by_changes(state, new_content, source) do
    new_document =
      new_content
      |> Document.new()
      |> Document.move_to(Document.cursor(state.document))

    patches = region_patches(state.document, new_document)

    apply_operation(
      state,
      {:changes, new_document, patches},
      EditSource.from_undo_source(source),
      {:changes, source, :clear}
    )
  end

  @spec replace_content_document_state(state(), Document.t(), BufState.edit_source()) :: state()
  defp replace_content_document_state(state, new_document, source) do
    event_source = EditSource.from_undo_source(source)
    apply_operation(state, {:full, new_document}, event_source, {:force_full, source, :clear})
  end

  @spec record_operation(state(), Operation.result(), EditSource.t()) :: state()
  defp record_operation(state, :unchanged, _event_source), do: state

  defp record_operation(state, {:edited, doc, delta}, event_source) do
    state
    |> push_undo(doc, EditSource.to_undo_source(event_source), delta)
    |> mark_dirty()
    |> record_edit(delta, event_source)
  end

  # A line shift is one undo step, but subscribers see one versioned delta per
  # changed line: LSP sync drops a delta whose version is not newer than the
  # one before it, so each delta advances the version exactly as a separate
  # edit would.
  @spec record_shift(state(), Document.t(), [EditDelta.t()], UndoPatch.t(), EditSource.t()) ::
          state()
  defp record_shift(state, new_doc, deltas, patch, source) do
    version = BufState.version(state)
    undo_source = EditSource.to_undo_source(source)
    first_sequence = ChangeLog.sequence(state.change_log) + 1

    state =
      state
      |> install_document(
        new_doc,
        &UndoHistory.record_edit(&1, version, patch, undo_source, now_ms())
      )
      |> Map.put(:change_log, ChangeLog.record_changes(state.change_log, deltas))

    deltas
    |> Enum.with_index(first_sequence)
    |> Enum.reduce(state, fn {delta, sequence}, acc ->
      acc |> BufState.mark_dirty() |> track_edit(delta, source, sequence)
    end)
    |> schedule_swap_write()
    |> schedule_auto_save()
  end

  @spec apply_operation(state(), operation_result(), EditSource.t(), operation_opts()) :: state()
  defp apply_operation(
         state,
         {:delta, new_buf, delta},
         source,
         {:force_delta, undo_source, :record_delta}
       ) do
    state
    |> push_undo_force(new_buf, undo_source, delta)
    |> mark_dirty()
    |> record_edit(delta, source)
  end

  defp apply_operation(state, {:batch, new_buf, patches}, source, {:batch, undo_source, :clear}) do
    state
    |> push_undo_batch(new_buf, undo_source, patches)
    |> mark_dirty()
    |> clear_edits(source)
  end

  defp apply_operation(
         state,
         {:delta, new_buf, delta},
         source,
         {:force_delta, undo_source, :clear}
       ) do
    state
    |> push_undo_force(new_buf, undo_source, delta)
    |> mark_dirty()
    |> clear_edits(delta, source)
  end

  defp apply_operation(
         state,
         {:changes, new_buf, patches},
         source,
         {:changes, undo_source, :clear}
       ) do
    state
    |> push_undo_batch(new_buf, undo_source, patches)
    |> mark_dirty()
    |> clear_edits(source)
    |> Map.put(:decorations, Decorations.new())
  end

  defp apply_operation(state, {:full, new_buf}, source, {:force_full, undo_source, :clear}) do
    state
    |> push_undo_force_full(new_buf, undo_source)
    |> mark_dirty()
    |> clear_edits(source)
    # Reset decorations so search highlights, diagnostics, and agent
    # decorations don't stay anchored to text that no longer exists, matching
    # replace_generated_content and accept_saved_content.
    |> Map.put(:decorations, Decorations.new())
  end

  defp apply_operation(state, {:full, new_buf}, source, {:full, undo_source, :clear}) do
    state
    |> push_undo_full(new_buf, undo_source)
    |> mark_dirty()
    |> clear_edits(source)
  end

  @spec push_undo(state(), Document.t(), BufState.edit_source(), EditDelta.t()) :: state()
  defp push_undo(state, new_buf, source, delta) do
    patch = UndoPatch.from_delta(delta, state.document)
    version = BufState.version(state)

    install_document(
      state,
      new_buf,
      &UndoHistory.record_edit(&1, version, patch, source, now_ms())
    )
  end

  @spec push_undo_full(state(), Document.t(), BufState.edit_source()) :: state()
  defp push_undo_full(state, new_buf, source) do
    patches = region_patches(state.document, new_buf)
    version = BufState.version(state)

    install_document(
      state,
      new_buf,
      &UndoHistory.record_edit(&1, version, patches, source, now_ms())
    )
  end

  @spec push_undo_batch(state(), Document.t(), BufState.edit_source(), [UndoPatch.t()]) :: state()
  defp push_undo_batch(state, new_buf, source, patches) do
    version = BufState.version(state)

    install_document(
      state,
      new_buf,
      &UndoHistory.record_edit_batch(&1, version, patches, source, now_ms())
    )
  end

  @spec push_undo_force(state(), Document.t(), BufState.edit_source(), EditDelta.t()) :: state()
  defp push_undo_force(state, new_buf, source, delta) do
    patch = UndoPatch.from_delta(delta, state.document)
    version = BufState.version(state)

    install_document(
      state,
      new_buf,
      &UndoHistory.record_edit_force(&1, version, patch, source, now_ms())
    )
  end

  @spec push_undo_force_full(state(), Document.t(), BufState.edit_source()) :: state()
  defp push_undo_force_full(state, new_buf, source) do
    patches = region_patches(state.document, new_buf)
    version = BufState.version(state)

    install_document(
      state,
      new_buf,
      &UndoHistory.record_edit_batch(&1, version, patches, source, now_ms())
    )
  end

  # The one place a content change installs its document and history.
  # The history must describe the document before the change, and the recorded history the document after it.
  # Both size checks are O(1). When either fails, or recording raises, authorship is lost but the buffer survives.
  @spec install_document(state(), Document.t(), (UndoHistory.t() -> UndoHistory.t())) :: state()
  defp install_document(state, document, record) do
    history =
      state.undo_history
      |> history_in_step(state, state.document, :before)
      |> record_history(state, document, record)
      |> history_in_step(state, document, :after)

    %{state | document: document, undo_history: history}
  end

  # Content read from disk keeps Minga's unreviewed steps; see `UndoHistory.reload/3`.
  @spec reload_history(state(), Document.t()) :: UndoHistory.t()
  defp reload_history(state, new_document) do
    state.undo_history
    |> history_in_step(state, state.document, :before)
    |> record_history(state, new_document, &UndoHistory.reload(&1, state.document, new_document))
    |> history_in_step(state, new_document, :after)
  end

  @spec with_history_in_step(state()) :: state()
  defp with_history_in_step(state),
    do: %{
      state
      | undo_history: history_in_step(state.undo_history, state, state.document, :before)
    }

  @spec record_history(
          UndoHistory.t(),
          state(),
          Document.t(),
          (UndoHistory.t() -> UndoHistory.t())
        ) :: UndoHistory.t()
  defp record_history(history, state, document, record) do
    record.(history)
  rescue
    exception -> lost_history(state, document, Exception.message(exception))
  end

  @spec history_in_step(UndoHistory.t(), state(), Document.t(), :before | :after) ::
          UndoHistory.t()
  defp history_in_step(history, state, document, moment) do
    if UndoHistory.size(history) == Document.content_byte_size(document),
      do: history,
      else:
        lost_history(
          state,
          document,
          "history describes #{UndoHistory.size(history)} bytes #{moment} an edit, " <>
            "the document #{Document.content_byte_size(document)}"
        )
  end

  # Starts the history again for `document`, logs why, and tells the user in *Messages*.
  @spec lost_history(state(), Document.t(), String.t()) :: UndoHistory.t()
  defp lost_history(state, document, reason) do
    Minga.Log.error(:editor, "Buffer history and authorship reset: #{reason}")

    name = display_name_from_state(state)
    message = "Undo history and authorship for #{name} were reset after an internal error."
    log_to_messages(state, message <> " Your text is unchanged.", :error)

    UndoHistory.new(document)
  end

  # A whole-content replacement records one patch per changed region.
  # The lines it left alone keep their authors, and nobody's text between two changes counts as rewritten.
  # An unchanged replacement still records one empty patch.
  @spec region_patches(Document.t(), Document.t()) :: nonempty_list(UndoPatch.t())
  defp region_patches(old_document, new_document) do
    case UndoPatch.changes(old_document, new_document) do
      [] -> [UndoPatch.from_documents(old_document, new_document)]
      changes -> changes
    end
  end

  @spec line_authors_in(state(), non_neg_integer(), non_neg_integer()) :: [[Provenance.author()]]
  defp line_authors_in(state, first_line, count) do
    line_count = Document.line_count(state.document)
    last_line = min(first_line + count, line_count) - 1

    if first_line > last_line,
      do: [],
      else: authors_in_lines(state, first_line, last_line, line_count)
  end

  @spec authors_in_lines(state(), non_neg_integer(), non_neg_integer(), pos_integer()) :: [
          [Provenance.author()]
        ]
  defp authors_in_lines(state, first_line, last_line, line_count) do
    document = state.document

    bounds =
      Enum.map(first_line..last_line//1, fn line ->
        {Lines.start_of(document, line), line_end(document, line, line_count)}
      end)

    spans =
      state.undo_history
      |> UndoHistory.provenance()
      |> Provenance.spans(
        Lines.start_of(document, first_line),
        line_end(document, last_line, line_count)
      )

    authors_by_line(bounds, spans)
  end

  # A line's bytes run up to the next line's start, so they include its newline.
  @spec line_end(Document.t(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp line_end(document, line, line_count) when line + 1 < line_count,
    do: Lines.start_of(document, line + 1)

  defp line_end(document, _line, _line_count), do: Document.content_byte_size(document)

  # Both lists are in document order, so one walk assigns every span to the lines it covers.
  @spec authors_by_line([{non_neg_integer(), non_neg_integer()}], [Provenance.span()]) :: [
          [Provenance.author()]
        ]
  defp authors_by_line([], _spans), do: []

  defp authors_by_line([{line_start, line_end} | lines], spans) do
    spans = Enum.drop_while(spans, fn {_from, to, _author, _key} -> to <= line_start end)

    authors =
      spans
      |> Enum.take_while(fn {from, _to, _author, _key} -> from < line_end end)
      |> Enum.map(fn {_from, _to, author, _key} -> author end)
      |> Enum.uniq()

    [authors | authors_by_line(lines, spans)]
  end

  # Installs the document an undo, redo or agent revert produced.
  # It takes back its earlier version only when the history returned exactly to that state; otherwise it is new.
  @spec install_restore(state(), Restore.t(), UndoHistory.t()) :: state()
  defp install_restore(state, %Restore{version: :advance} = restore, undo_history) do
    undo_history = history_in_step(undo_history, state, restore.document, :after)

    %{state | document: restore.document, undo_history: undo_history}
    |> mark_dirty()
    |> clear_edits(EditSource.from_undo_source(restore.source))
  end

  defp install_restore(state, %Restore{} = restore, undo_history) do
    undo_history = history_in_step(undo_history, state, restore.document, :after)

    %{
      BufState.restore_version(state, restore.version)
      | document: restore.document,
        undo_history: undo_history
    }
    |> sync_dirty()
    |> clear_edits(EditSource.from_undo_source(restore.source))
  end

  # UndoHistory is clock-free; the process owns the coalescing clock.
  @spec now_ms() :: integer()
  defp now_ms, do: System.monotonic_time(:millisecond)

  # Logs an undo or redo that was refused because its patch no longer applies.
  @spec log_history_failure(:undo | :redo | :undo_agent_session, UndoPatch.apply_error()) :: :ok
  defp log_history_failure(operation, reason) do
    Minga.Log.warning(
      :editor,
      "Buffer #{operation} refused: its patch does not apply (#{reason}); content and history are unchanged"
    )
  end

  # Logs undo/redo source for non-user edits (diagnostic, gated by :log_level_editor).
  @spec log_undo_source(:undo | :redo, BufState.edit_source()) :: :ok
  defp log_undo_source(_action, :user), do: :ok

  defp log_undo_source(:undo, source) do
    Minga.Log.debug(:editor, "Undo: #{undo_source_label(source)} edit")
  end

  defp log_undo_source(:redo, source) do
    Minga.Log.debug(:editor, "Redo: #{undo_source_label(source)} edit")
  end

  @spec undo_source_label(BufState.edit_source()) :: String.t()
  defp undo_source_label({kind, task_id, step}), do: "#{kind} (task #{task_id}, step #{step})"
  defp undo_source_label(source), do: Atom.to_string(source)

  @swap_debounce_ms 5_000

  @spec admit_current_swap(state()) :: state()
  defp admit_current_swap(%{buffer_type: :file, file_path: path} = state)
       when is_binary(path) do
    if BufState.dirty?(state) and SwapState.configured?(state.swap) do
      # The only swap work in the buffer process: one copy of the text, once per quiet period.
      content =
        Minga.Telemetry.span([:minga, :swap, :write], %{stage: :snapshot}, fn ->
          Document.content(state.document)
        end)

      case SwapState.admit(state.swap, path, content) do
        {:start, snapshot, swap} -> start_swap_worker(%{state | swap: swap}, snapshot)
        {:pending, swap} -> %{state | swap: swap}
      end
    else
      state
    end
  end

  defp admit_current_swap(state), do: state

  @spec start_swap_worker(state(), SwapState.snapshot()) :: state()
  defp start_swap_worker(state, {generation, path, content} = snapshot) do
    owner = self()
    backend = SwapState.backend(state.swap)
    opts = SwapState.backend_options(state.swap, generation)

    {worker, monitor} =
      spawn_monitor(fn ->
        run_swap_preparation(owner, generation, path, content, backend, opts)
      end)

    %{state | swap: SwapState.worker_started(state.swap, snapshot, worker, monitor)}
  end

  @spec run_swap_preparation(
          pid(),
          SwapState.generation(),
          String.t(),
          binary(),
          module(),
          keyword()
        ) :: :ok
  defp run_swap_preparation(owner, generation, path, content, backend, opts) do
    owner_monitor = Process.monitor(owner)
    coordinator = self()

    io_worker =
      spawn_link(fn ->
        result =
          Minga.Telemetry.span(
            [:minga, :swap, :write],
            %{stage: :prepare, byte_count: byte_size(content)},
            fn -> backend.prepare(path, content, opts) end
          )

        send(coordinator, {:swap_prepare_result, result})
      end)

    receive do
      {:swap_prepare_result, result} ->
        Process.demonitor(owner_monitor, [:flush])
        send(owner, {:swap_prepared, self(), generation, result})
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        Process.exit(io_worker, :kill)
        :ok
    end
  end

  @spec handle_prepared_swap(state(), pid(), SwapState.generation(), term()) :: state()
  defp handle_prepared_swap(state, worker, generation, {:ok, prepared}) do
    case SwapState.publication_status(state.swap, worker, generation) do
      :current ->
        state
        |> publish_prepared_swap(prepared)
        |> handle_publication_result()
        |> complete_swap_work(worker, generation)

      :obsolete ->
        discard_prepared_swap(state, prepared)
        complete_swap_work(state, worker, generation)

      :unknown ->
        discard_prepared_swap(state, prepared)
        state
    end
  end

  defp handle_prepared_swap(state, worker, generation, {:error, reason}) do
    if SwapState.publication_status(state.swap, worker, generation) == :current do
      log_swap_failure(state, reason)
    end

    complete_swap_work(state, worker, generation)
  end

  @spec publish_prepared_swap(state(), term()) :: {state(), :ok | {:error, term()}}
  defp publish_prepared_swap(state, prepared) do
    backend = SwapState.backend(state.swap)

    result =
      Minga.Telemetry.span([:minga, :swap, :write], %{stage: :publish}, fn ->
        swap_backend_call(fn -> backend.publish(prepared) end)
      end)

    {state, result}
  end

  @spec handle_publication_result({state(), :ok | {:error, term()}}) :: state()
  defp handle_publication_result({state, :ok}), do: state

  defp handle_publication_result({state, {:error, reason}}) do
    log_swap_failure(state, reason)
    :ok = delete_swap_file(state)
    state
  end

  @spec discard_prepared_swap(state(), term()) :: :ok
  defp discard_prepared_swap(state, prepared) do
    backend = SwapState.backend(state.swap)

    case swap_backend_call(fn -> backend.discard(prepared) end) do
      :ok -> :ok
      {:error, reason} -> log_swap_failure(state, {:discard_failed, reason})
    end
  end

  @spec complete_swap_work(state(), pid(), SwapState.generation()) :: state()
  defp complete_swap_work(state, worker, generation) do
    case SwapState.complete(state.swap, worker, generation) do
      {:ok, monitor, pending, swap} ->
        Process.demonitor(monitor, [:flush])
        start_pending_swap(%{state | swap: swap}, pending)

      :unknown ->
        state
    end
  end

  @spec start_pending_swap(state(), SwapState.snapshot() | nil) :: state()
  defp start_pending_swap(state, nil), do: state
  defp start_pending_swap(state, snapshot), do: start_swap_worker(state, snapshot)

  @spec maybe_log_swap_worker_failure(state(), term()) :: :ok
  defp maybe_log_swap_worker_failure(state, reason) do
    log_swap_failure(state, {:worker_stopped, reason})
  end

  @spec log_swap_failure(state(), term()) :: :ok
  defp log_swap_failure(state, reason) do
    name = if is_binary(state.file_path), do: Path.basename(state.file_path), else: "buffer"
    Minga.Log.warning(:editor, "Failed to write swap file for #{name}: #{inspect(reason)}")
  end

  @spec swap_backend_call((-> term())) :: :ok | {:error, term()}
  defp swap_backend_call(operation) when is_function(operation, 0) do
    case operation.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_backend_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec revoke_swap_writes(state()) :: state()
  defp revoke_swap_writes(state) do
    {timer, active, swap} = SwapState.invalidate(state.swap)

    if is_reference(timer), do: Process.cancel_timer(timer)

    state = %{state | swap: swap}
    revoke_active_swap(state, active)
  end

  @spec revoke_active_swap(state(), SwapState.active_work() | nil) :: state()
  defp revoke_active_swap(state, nil), do: state

  defp revoke_active_swap(state, {{generation, _path, _content}, worker, monitor}) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end

    discard_prepared_message(state, worker, generation)
    state
  end

  @spec discard_prepared_message(state(), pid(), SwapState.generation()) :: :ok
  defp discard_prepared_message(state, worker, generation) do
    receive do
      {:swap_prepared, ^worker, ^generation, {:ok, prepared}} ->
        discard_prepared_swap(state, prepared)

      {:swap_prepared, ^worker, ^generation, {:error, _reason}} ->
        :ok
    after
      0 -> :ok
    end
  end

  @spec clear_swap(state()) :: state()
  defp clear_swap(state) do
    state = revoke_swap_writes(state)
    :ok = delete_swap_file(state)
    state
  end

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
      state |> schedule_swap_write() |> schedule_auto_save()
    else
      state |> clear_swap() |> cancel_auto_save_timer()
    end
  end

  @spec mark_saved(state(), Minga.Buffer.SaveState.metadata(), String.t()) :: state()
  defp mark_saved(state, metadata, content) do
    state = clear_swap(state)
    state = BufState.mark_saved(state, metadata, content)
    cancel_auto_save_timer(state)
  end

  # Schedule a debounced swap file write. Cancels any pending timer
  # so rapid edits only produce one write after 5 seconds of quiet.
  @spec schedule_swap_write(state()) :: state()
  defp schedule_swap_write(%{buffer_type: :file, file_path: path} = state)
       when is_binary(path) do
    if SwapState.configured?(state.swap) do
      state = cancel_swap_timer(state)
      token = make_ref()
      timer_start = SwapState.timer_start(state.swap)
      timer = timer_start.(self(), {:write_swap, token}, @swap_debounce_ms)
      %{state | swap: SwapState.schedule(state.swap, timer, token)}
    else
      state
    end
  end

  defp schedule_swap_write(state), do: state

  @spec cancel_swap_timer(state()) :: state()
  defp cancel_swap_timer(state) do
    {timer, swap} = SwapState.take_timer(state.swap)

    if is_reference(timer), do: Process.cancel_timer(timer)

    %{state | swap: swap}
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

  @spec broadcast_buffer_path_changed(String.t() | nil, state()) :: :ok
  defp broadcast_buffer_path_changed(path, %{file_path: path}), do: :ok

  defp broadcast_buffer_path_changed(_old_path, state) do
    Events.broadcast(
      :buffer_path_changed,
      %Events.BufferEvent{buffer: self(), path: state.file_path},
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
  defp delete_swap_file(%{file_path: path} = state) when is_binary(path) do
    if SwapState.configured?(state.swap) do
      delete_configured_swap(state, path)
    else
      :ok
    end
  end

  defp delete_swap_file(_state), do: :ok

  @spec delete_configured_swap(state(), String.t()) :: :ok
  defp delete_configured_swap(state, path) do
    backend = SwapState.backend(state.swap)
    opts = SwapState.backend_options(state.swap, 0)

    case swap_backend_call(fn -> backend.delete(path, opts) end) do
      :ok -> :ok
      {:error, reason} -> log_swap_failure(state, {:delete_failed, reason})
    end
  end

  # ── Conflict selection ──

  @spec conflict_region(Entry.t()) :: Conflict.region()
  defp conflict_region(%Entry{start_line: start_line, end_line: end_line}),
    do: %{start_line: start_line, end_line: end_line}

  @spec find_conflict([Entry.t()], Conflict.target()) :: {Entry.t(), non_neg_integer()} | nil
  defp find_conflict(entries, {:cursor, line}) do
    case MergeConflict.at_line(entries, line) do
      %Entry{} = entry -> {entry, line}
      nil -> nil
    end
  end

  defp find_conflict(entries, {:region, %{start_line: start_line, end_line: end_line}}) do
    case Enum.find(entries, &match?(%Entry{start_line: ^start_line, end_line: ^end_line}, &1)) do
      %Entry{} = entry -> {entry, start_line}
      nil -> nil
    end
  end

  # ── Edit delta tracking ──

  @spec inspection_snapshot_reply(
          state(),
          non_neg_integer(),
          pos_integer(),
          :live | Document.position()
        ) :: {:reply, InspectionSnapshot.t(), state()}
  defp inspection_snapshot_reply(state, viewport_start, viewport_count, cursor_source) do
    cursor = inspection_cursor(state.document, cursor_source)
    {cursor_line, _cursor_column} = cursor

    snapshot = %InspectionSnapshot{
      version: BufState.version(state),
      line_count: Document.line_count(state.document),
      cursor: cursor,
      cursor_line_text: Document.line_at(state.document, cursor_line),
      display_name: display_name_from_state(state),
      file_path: state.file_path,
      viewport_start: viewport_start,
      viewport_lines: Document.lines(state.document, viewport_start, viewport_count)
    }

    {:reply, snapshot, state}
  end

  @spec inspection_cursor(Document.t(), :live | Document.position()) :: Document.position()
  defp inspection_cursor(document, :live), do: Document.cursor(document)

  defp inspection_cursor(document, {requested_line, requested_column}) do
    line = min(requested_line, Document.line_count(document) - 1)
    line_text = Document.line_at(document, line)
    {line, Cursor.caret_column(line_text, requested_column)}
  end

  @spec record_edit(state(), EditDelta.t(), EditSource.t()) :: state()
  defp record_edit(state, delta, source) do
    state = %{state | change_log: ChangeLog.record_change(state.change_log, delta)}
    track_edit(state, delta, source, ChangeLog.sequence(state.change_log))
  end

  # Applies one recorded delta to the buffer's derived state and queues its
  # change event under the delta's own change-log sequence.
  @spec track_edit(state(), EditDelta.t(), EditSource.t(), ChangeLog.sequence()) :: state()
  defp track_edit(state, delta, source, sequence) do
    state = %{
      state
      | conflict_index: ConflictIndex.apply_edit(state.conflict_index, state.document, delta)
    }

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

    defer_buffer_changed(state, delta, source, sequence)
    state
  end

  # Clear pending edits to force HighlightSync into full content sync.
  # Used for operations where computing accurate deltas is impractical
  # (undo, redo, multi-edit batches, full content replacement).
  @spec clear_edits(state(), EditDelta.t(), EditSource.t()) :: state()
  defp clear_edits(state, delta, source) do
    state = %{
      state
      | change_log: ChangeLog.clear(state.change_log),
        conflict_index: ConflictIndex.apply_edit(state.conflict_index, state.document, delta)
    }

    defer_buffer_changed(state, nil, source)
    state
  end

  @spec clear_edits(state(), EditSource.t()) :: state()
  defp clear_edits(state, source) do
    state = %{
      state
      | change_log: ChangeLog.clear(state.change_log),
        conflict_index: ConflictIndex.new(state.document)
    }

    defer_buffer_changed(state, nil, source)
    state
  end

  @spec rebuild_conflict_index(state()) :: state()
  defp rebuild_conflict_index(state) do
    %{state | conflict_index: ConflictIndex.new(state.document)}
  end

  # Returns the minimum number of leading lines whose cumulative byte
  # offset reaches `min_bytes`. Used by bounded_append to satisfy a byte
  # capacity limit after the line-count trim.
  @spec lines_for_byte_target(Document.t(), non_neg_integer()) :: non_neg_integer()
  defp lines_for_byte_target(_doc, min_bytes) when min_bytes <= 0, do: 0

  defp lines_for_byte_target(doc, min_bytes) do
    total = Document.line_count(doc)
    do_lines_for_byte_target(doc, min_bytes, 1, total)
  end

  defp do_lines_for_byte_target(_doc, _target, line, total) when line >= total, do: total

  defp do_lines_for_byte_target(doc, target, line, total) do
    if Lines.start_of(doc, line) >= target do
      line
    else
      do_lines_for_byte_target(doc, target, line + 1, total)
    end
  end

  @spec sync_snapshot_changes(state(), :full | ChangeLog.sequence()) :: SyncSnapshot.changes()
  defp sync_snapshot_changes(state, :full), do: {:full, Document.content(state.document)}

  defp sync_snapshot_changes(state, cursor) do
    case ChangeLog.changes_since(state.change_log, cursor) do
      {:ok, _sequence, []} -> :unchanged
      {:ok, _sequence, edits} -> {:edits, edits}
      {:reset_required, _sequence} -> {:full, Document.content(state.document)}
    end
  end

  # ── move_if_possible helpers ──

  @spec renderer_changed_snapshot(
          BufState.t(),
          {:ok, [Minga.Buffer.EditDelta.t()]} | :reset_required,
          {non_neg_integer(), non_neg_integer()} | nil
        ) :: RenderSnapshot.t() | nil
  defp renderer_changed_snapshot(_state, :reset_required, _prior_range), do: nil

  defp renderer_changed_snapshot(state, {:ok, changes}, prior_range) do
    case EditDelta.affected_line_range(changes, prior_range) do
      nil ->
        nil

      {first_line, last_line} ->
        line_count = Document.line_count(state.document)
        bounded_first = min(first_line, line_count - 1)
        bounded_last = min(max(last_line, bounded_first), line_count - 1)
        bounded_render_snapshot(state, bounded_first, bounded_last - bounded_first + 1)
    end
  end

  @spec snapshot_lines(Document.t(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  @spec bounded_render_snapshot(BufState.t(), non_neg_integer(), non_neg_integer()) ::
          RenderSnapshot.t()
  defp bounded_render_snapshot(state, first_line, count) do
    document = state.document

    %RenderSnapshot{
      cursor: Document.cursor(document),
      line_count: Document.line_count(document),
      lines: snapshot_lines(document, first_line, count),
      first_line: first_line,
      file_path: state.file_path,
      filetype: state.filetype,
      buffer_type: state.buffer_type,
      dirty: BufState.dirty?(state),
      name: state.name,
      read_only: state.read_only,
      first_line_byte_offset: Position.point_for(document, {first_line, 0}),
      version: BufState.version(state),
      options: resolved_buffer_local_options(state),
      decorations: state.decorations,
      change_sequence: ChangeLog.sequence(state.change_log)
    }
  end

  defp snapshot_lines(_document, _first_line, 0), do: []
  defp snapshot_lines(document, first_line, count), do: Lines.slice(document, first_line, count)

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
