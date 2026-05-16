defmodule Minga.Buffer do
  @moduledoc """
  Domain facade for buffer operations.

  This is the only valid entry point for code outside the buffer domain.
  All buffer operations go through this module: reading content, moving
  cursors, editing text, persisting files, and managing decorations.

  Internally delegates to `Minga.Buffer.Process` (GenServer) and
  `Minga.Buffer.Document` (pure data structure). External callers
  should never reference those modules directly.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Process, as: BufferProcess

  @type t :: GenServer.server()
  @type server :: t()
  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}
  @type direction :: :left | :right | :up | :down
  @type document :: Document.t()
  @type text_edit :: BufferProcess.text_edit()
  @type boundary :: BufferProcess.boundary()
  @type replace_edit :: BufferProcess.replace_edit()
  @type replace_result :: BufferProcess.replace_result()

  # ── Lifecycle ──────────────────────────────────────────────────────

  @doc "Supervisor child spec for starting a buffer process."
  @spec child_spec([BufferProcess.start_opt()]) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: BufferProcess

  @doc "Start a new buffer process."
  @spec start_link([BufferProcess.start_opt()]) :: GenServer.on_start()
  defdelegate start_link(opts \\ []), to: BufferProcess

  @doc "Open a file into the buffer, replacing current content."
  @spec open(t(), String.t()) :: :ok | {:error, term()}
  defdelegate open(server, file_path), to: BufferProcess

  @doc "Look up a buffer process by its file path. Returns `:not_found` if no buffer has that file open."
  @spec pid_for_path(String.t()) :: {:ok, pid()} | :not_found
  defdelegate pid_for_path(path), to: BufferProcess

  @doc """
  Returns the pid of the BEAM-wide singleton `*Messages*` buffer.

  Available in headless mode, before any editor exists. Returns `nil`
  only if `Minga.Buffer.Messages` is not running (e.g. boot ordering bug).
  """
  @spec messages() :: pid() | nil
  defdelegate messages(), to: Minga.Buffer.Messages, as: :pid

  @doc """
  Returns the pid for a buffer at `path`, starting one if it doesn't exist.

  If a buffer is already registered for `path`, returns its pid immediately.
  Otherwise, starts a new buffer under `Minga.Buffer.Supervisor` and
  broadcasts a `:buffer_opened` event so the Editor and other subscribers
  can pick it up.

  Used by agent tools to guarantee every edited file has a buffer with
  undo integration, without depending on the Editor (Layer 2).
  """
  @spec ensure_for_path(String.t()) :: {:ok, pid()} | {:error, term()}
  @spec ensure_for_path(String.t(), Minga.Events.registry()) :: {:ok, pid()} | {:error, term()}
  def ensure_for_path(path, events_registry \\ Minga.Events.default_registry())
      when is_binary(path) do
    abs_path = Path.expand(path)

    case pid_for_path(abs_path) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        if File.exists?(abs_path) do
          start_buffer_for_path(abs_path, events_registry)
        else
          {:error, :enoent}
        end
    end
  end

  @spec start_buffer_for_path(String.t(), Minga.Events.registry()) ::
          {:ok, pid()} | {:error, term()}
  defp start_buffer_for_path(abs_path, events_registry) do
    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {__MODULE__, file_path: abs_path, events_registry: events_registry}
         ) do
      {:ok, pid} ->
        Minga.Events.broadcast(
          :buffer_opened,
          %Minga.Events.BufferEvent{
            buffer: pid,
            path: abs_path
          },
          events_registry
        )

        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Content ────────────────────────────────────────────────────────

  @doc "Full text content of the buffer."
  @spec content(t()) :: String.t()
  defdelegate content(server), to: BufferProcess

  @doc "Content and cursor position in a single call (avoids two round-trips)."
  @spec content_and_cursor(t()) :: {String.t(), position()}
  defdelegate content_and_cursor(server), to: BufferProcess

  @doc "A range of lines starting at `start` (0-indexed), returning `count` lines."
  @spec lines(t(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  defdelegate lines(server, start, count), to: BufferProcess

  @doc "Content of lines from `start_line` to `end_line` (inclusive, 0-indexed)."
  @spec content_on_lines(t(), non_neg_integer(), non_neg_integer()) :: String.t()
  defdelegate content_on_lines(server, start_line, end_line), to: BufferProcess

  @doc "Text between two positions (end inclusive, includes the character at end_pos)."
  @spec text_between_inclusive(t(), position(), position()) :: String.t()
  defdelegate text_between_inclusive(server, start_pos, end_pos), to: BufferProcess

  @doc "Number of lines in the buffer."
  @spec line_count(t()) :: pos_integer()
  defdelegate line_count(server), to: BufferProcess

  @doc "Byte offset of the start of a line (for tree-sitter integration)."
  @spec byte_offset_for_line(t(), non_neg_integer()) :: non_neg_integer()
  defdelegate byte_offset_for_line(server, line), to: BufferProcess

  # ── Cursor ─────────────────────────────────────────────────────────

  @doc "Current cursor position as `{line, col}`."
  @spec cursor(t()) :: position()
  defdelegate cursor(server), to: BufferProcess

  @doc "Move the cursor to an exact position."
  @spec move_to(t(), position()) :: :ok
  defdelegate move_to(server, pos), to: BufferProcess

  @doc "Move the cursor one step in a direction."
  @spec move(t(), direction()) :: :ok
  defdelegate move(server, direction), to: BufferProcess

  @doc "Move cursor if possible, returning the result position and whether a boundary was hit."
  @spec move_if_possible(t(), :left | :right) ::
          {:ok, position()} | {:at_boundary, position()}
  defdelegate move_if_possible(server, direction), to: BufferProcess

  # ── Editing ────────────────────────────────────────────────────────

  @doc "Insert a single character at the cursor."
  @spec insert_char(t(), String.t(), Minga.Buffer.EditSource.t()) :: :ok
  defdelegate insert_char(server, char, source \\ Minga.Buffer.EditSource.user()),
    to: BufferProcess

  @doc "Insert a multi-character string at the cursor."
  @spec insert_text(t(), String.t(), Minga.Buffer.EditSource.t()) :: :ok
  defdelegate insert_text(server, text, source \\ Minga.Buffer.EditSource.user()),
    to: BufferProcess

  @doc "Replace text in a range with new text (the general-purpose edit operation)."
  @spec apply_edit(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          Minga.Buffer.EditSource.t()
        ) :: :ok
  defdelegate apply_edit(
                server,
                start_line,
                start_col,
                end_line,
                end_col,
                new_text,
                source \\ Minga.Buffer.EditSource.user()
              ),
              to: BufferProcess

  @doc "Apply a batch of edits atomically (for LSP workspace edits)."
  @spec apply_edits(t(), [text_edit()], Minga.Buffer.EditSource.t()) :: :ok
  defdelegate apply_edits(server, edits, source \\ Minga.Buffer.EditSource.lsp(:unknown)),
    to: BufferProcess

  @doc "Delete the character before the cursor."
  @spec delete_before(t()) :: :ok
  defdelegate delete_before(server), to: BufferProcess

  @doc "Delete the character at the cursor."
  @spec delete_at(t()) :: :ok
  defdelegate delete_at(server), to: BufferProcess

  @doc "Delete text between two positions."
  @spec delete_range(t(), position(), position()) :: :ok
  defdelegate delete_range(server, from_pos, to_pos), to: BufferProcess

  @doc "Delete lines from `start_line` to `end_line` (inclusive)."
  @spec delete_lines(t(), non_neg_integer(), non_neg_integer()) :: :ok
  defdelegate delete_lines(server, start_line, end_line), to: BufferProcess

  @doc "Clear the contents of a single line."
  @spec clear_line(t(), non_neg_integer()) :: {:ok, String.t()}
  defdelegate clear_line(server, line), to: BufferProcess

  @doc "Replace the entire buffer content."
  @spec replace_content(t(), String.t(), Minga.Buffer.State.edit_source()) ::
          :ok | {:error, term()}
  defdelegate replace_content(server, new_content, source \\ :user), to: BufferProcess

  @doc "Replace generated/internal content, bypassing user read-only restrictions."
  @spec replace_generated_content(t(), String.t()) :: :ok
  defdelegate replace_generated_content(server, new_content), to: BufferProcess

  @doc "Accept content as the saved base revision and clear dirty state."
  @spec accept_saved_content(t(), String.t()) :: :ok
  defdelegate accept_saved_content(server, new_content), to: BufferProcess

  @doc "Find and replace the first occurrence of `old_text` with `new_text`."
  @spec find_and_replace(t(), String.t(), String.t(), boundary()) ::
          {:ok, String.t()} | {:error, String.t()}
  defdelegate find_and_replace(server, old_text, new_text, boundary \\ nil), to: BufferProcess

  @doc "Find and replace multiple patterns atomically."
  @spec find_and_replace_batch(t(), [replace_edit()], boundary()) ::
          {:ok, [replace_result()]} | {:error, String.t()}
  defdelegate find_and_replace_batch(server, edits, boundary \\ nil), to: BufferProcess

  @doc "Append text to the end of the buffer."
  @spec append(t(), String.t()) :: :ok
  defdelegate append(server, text), to: BufferProcess

  # ── Undo/Redo ──────────────────────────────────────────────────────

  @doc "Undo the last edit."
  @spec undo(t()) :: :ok | :empty
  defdelegate undo(server), to: BufferProcess

  @doc "Redo the last undone edit."
  @spec redo(t()) :: :ok | :empty
  defdelegate redo(server), to: BufferProcess

  @doc "Force the next edit to start a new undo group."
  @spec break_undo_coalescing(t()) :: :ok
  defdelegate break_undo_coalescing(server), to: BufferProcess

  # ── File persistence ───────────────────────────────────────────────

  @doc "Save the buffer to disk."
  @spec save(t()) :: :ok | {:error, term()}
  defdelegate save(server), to: BufferProcess

  @doc """
  Saves all dirty file-backed buffers to disk.

  Enumerates the Buffer.Registry, filters for dirty buffers, and saves each one.
  Read-only buffers and save failures are logged as warnings but do not block
  other saves. Returns the count of successfully saved buffers and a list of
  any warnings (path + error reason).
  """
  @spec save_all_dirty() :: {non_neg_integer(), [String.t()]}
  def save_all_dirty do
    pids = Registry.select(Minga.Buffer.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])

    {saved, warnings} =
      Enum.reduce(pids, {0, []}, fn pid, {count, warns} ->
        save_if_dirty(pid, count, warns)
      end)

    {saved, Enum.reverse(warnings)}
  end

  @spec save_if_dirty(pid(), non_neg_integer(), [String.t()]) ::
          {non_neg_integer(), [String.t()]}
  defp save_if_dirty(pid, count, warns) do
    if Process.alive?(pid) and BufferProcess.dirty?(pid) do
      case BufferProcess.save(pid) do
        :ok ->
          {count + 1, warns}

        {:error, reason} ->
          path = BufferProcess.file_path(pid) || "unknown"
          {count, ["failed to save #{path}: #{inspect(reason)}" | warns]}
      end
    else
      {count, warns}
    end
  catch
    :exit, _ -> {count, warns}
  end

  @doc "Save even if the buffer appears clean."
  @spec force_save(t()) :: :ok | {:error, term()}
  defdelegate force_save(server), to: BufferProcess

  @doc "Reload content from disk, discarding unsaved changes."
  @spec reload(t()) :: :ok | {:error, term()}
  defdelegate reload(server), to: BufferProcess

  @doc "Save the buffer to a new file path."
  @spec save_as(t(), String.t()) :: :ok | {:error, term()}
  defdelegate save_as(server, file_path), to: BufferProcess

  # ── Identity and metadata ──────────────────────────────────────────

  @doc "File path of the buffer, or nil for scratch buffers."
  @spec file_path(t()) :: String.t() | nil
  defdelegate file_path(server), to: BufferProcess

  @doc "Detected filetype (e.g., `:elixir`, `:json`)."
  @spec filetype(t()) :: atom()
  defdelegate filetype(server), to: BufferProcess

  @doc "Override the detected filetype."
  @spec set_filetype(t(), atom()) :: :ok
  defdelegate set_filetype(server, filetype), to: BufferProcess

  @doc "Logical name of the buffer (e.g., `*Messages*`), or nil for file buffers."
  @spec buffer_name(t()) :: String.t() | nil
  defdelegate buffer_name(server), to: BufferProcess

  @doc "Human-readable display name (file basename or buffer name)."
  @spec display_name(t()) :: String.t()
  defdelegate display_name(server), to: BufferProcess

  @doc "Whether the buffer has unsaved changes."
  @spec dirty?(t()) :: boolean()
  defdelegate dirty?(server), to: BufferProcess

  @doc "Whether the buffer is read-only."
  @spec read_only?(t()) :: boolean()
  defdelegate read_only?(server), to: BufferProcess

  @spec storage(t()) :: Minga.Buffer.State.storage()
  defdelegate storage(server), to: BufferProcess

  @doc "Whether the buffer is hidden from buffer lists."
  @spec unlisted?(t()) :: boolean()
  defdelegate unlisted?(server), to: BufferProcess

  @doc "Whether the buffer survives tab close (e.g., `*Messages*`)."
  @spec persistent?(t()) :: boolean()
  defdelegate persistent?(server), to: BufferProcess

  @doc "Buffer kind: `:file`, `:scratch`, or `:special`."
  @spec buffer_type(t()) :: :file | :scratch | :special
  defdelegate buffer_type(server), to: BufferProcess

  @doc "Monotonic version counter (incremented on every content change)."
  @spec version(t()) :: non_neg_integer()
  defdelegate version(server), to: BufferProcess

  # ── Per-buffer options ─────────────────────────────────────────────

  @doc "Read a per-buffer option (falls back to global config)."
  @spec get_option(t(), atom()) :: term()
  defdelegate get_option(server, name), to: BufferProcess

  @doc "Set a per-buffer option override."
  @spec set_option(t(), atom(), term()) :: {:ok, term()} | {:error, String.t()}
  defdelegate set_option(server, name, value), to: BufferProcess

  @doc "Returns all buffer option values currently cached on this buffer."
  @spec local_options(t()) :: %{atom() => term()}
  defdelegate local_options(server), to: BufferProcess

  @doc "Returns only options explicitly overridden on this buffer."
  @spec local_option_overrides(t()) :: %{atom() => term()}
  defdelegate local_option_overrides(server), to: BufferProcess

  # ── Snapshots ──────────────────────────────────────────────────────

  @doc "Capture a snapshot of the document state (for undo boundaries and tab switching)."
  @spec snapshot(t()) :: document()
  defdelegate snapshot(server), to: BufferProcess

  @doc "Commit a previously captured document snapshot."
  @spec commit_snapshot(t(), document()) :: :ok
  defdelegate commit_snapshot(server, new_buf), to: BufferProcess

  @doc "Render-ready snapshot of visible lines for the rendering pipeline."
  @spec render_snapshot(t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Buffer.RenderSnapshot.t()
  defdelegate render_snapshot(server, first_line, count), to: BufferProcess

  # ── Edit deltas (for LSP incremental sync) ─────────────────────────

  @doc "Consume edit deltas accumulated since the given consumer's last read, or return `:reset_required` when the consumer must full-sync."
  @spec consume_edit_deltas(t(), atom()) :: BufferProcess.edit_delta_update()
  defdelegate consume_edit_deltas(server, consumer_id), to: BufferProcess

  # ── Decorations ────────────────────────────────────────────────────

  @doc "Current decoration state (highlights, virtual text, folds, etc.)."
  @spec decorations(t()) :: Minga.Core.Decorations.t()
  defdelegate decorations(server), to: BufferProcess

  @doc "Version counter for decorations (for change detection)."
  @spec decorations_version(t()) :: non_neg_integer()
  defdelegate decorations_version(server), to: BufferProcess

  @doc "Apply a batch of decoration changes atomically."
  @spec batch_decorations(t(), (Minga.Core.Decorations.t() -> Minga.Core.Decorations.t())) ::
          :ok
  defdelegate batch_decorations(server, fun), to: BufferProcess

  @doc "Replace buffer content and apply decorations in one atomic operation."
  @spec replace_content_with_decorations(t(), String.t(), function(), keyword()) :: :ok
  defdelegate replace_content_with_decorations(server, content, decoration_fn, opts \\ []),
    to: BufferProcess

  @doc "Add a highlight range."
  @spec add_highlight(
          t(),
          Minga.Core.Decorations.highlight_range_pos(),
          Minga.Core.Decorations.highlight_range_pos(),
          keyword()
        ) :: reference()
  defdelegate add_highlight(server, start_pos, end_pos, opts), to: BufferProcess

  @doc "Remove a highlight by ID."
  @spec remove_highlight(t(), reference()) :: :ok
  defdelegate remove_highlight(server, id), to: BufferProcess

  @doc "Remove all highlights in a group."
  @spec remove_highlight_group(t(), atom()) :: :ok
  defdelegate remove_highlight_group(server, group), to: BufferProcess

  @doc "Add virtual text anchored to a line."
  @spec add_virtual_text(t(), Minga.Core.Decorations.highlight_range_pos(), keyword()) ::
          reference()
  defdelegate add_virtual_text(server, anchor, opts), to: BufferProcess

  @doc "Remove virtual text by ID."
  @spec remove_virtual_text(t(), reference()) :: :ok
  defdelegate remove_virtual_text(server, id), to: BufferProcess

  @doc "Add a block decoration (multi-line annotation) anchored to a line."
  @spec add_block_decoration(t(), non_neg_integer(), keyword()) :: reference()
  defdelegate add_block_decoration(server, anchor_line, opts), to: BufferProcess

  @doc "Remove a block decoration by ID."
  @spec remove_block_decoration(t(), reference()) :: :ok
  defdelegate remove_block_decoration(server, id), to: BufferProcess

  # ── Face overrides (per-buffer syntax highlighting customization) ──

  @doc "Current face override map."
  @spec face_overrides(t()) :: %{String.t() => keyword()}
  defdelegate face_overrides(server), to: BufferProcess

  @doc "Override a face's attributes for this buffer."
  @spec remap_face(t(), String.t(), keyword()) :: :ok
  defdelegate remap_face(server, face_name, attrs), to: BufferProcess

  @doc "Remove a face override for this buffer."
  @spec clear_face_override(t(), String.t()) :: :ok
  defdelegate clear_face_override(server, face_name), to: BufferProcess
end
