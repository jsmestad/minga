defmodule Minga.Buffer do
  @moduledoc """
  Domain facade for buffer operations.

  This is the only valid entry point for code outside the buffer domain.
  All buffer operations go through this module: reading content, moving
  cursors, editing text, persisting files, and managing decorations.

  Internally delegates to `Minga.Buffer.Server` (GenServer) and
  `Minga.Buffer.Document` (pure data structure). External callers
  should never reference those modules directly.
  """

  alias Minga.Buffer.Server

  @type server :: GenServer.server()
  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}
  @type direction :: :left | :right | :up | :down

  # ── Lifecycle ──────────────────────────────────────────────────────

  @doc "Supervisor child spec for starting a buffer process."
  @spec child_spec([Server.start_opt()]) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: Server

  @doc "Start a new buffer process."
  @spec start_link([Server.start_opt()]) :: GenServer.on_start()
  defdelegate start_link(opts \\ []), to: Server

  @doc "Open a file into the buffer, replacing current content."
  @spec open(server(), String.t()) :: :ok | {:error, term()}
  defdelegate open(server, file_path), to: Server

  @doc "Look up a buffer process by its file path. Returns `:not_found` if no buffer has that file open."
  @spec pid_for_path(String.t()) :: {:ok, pid()} | :not_found
  defdelegate pid_for_path(path), to: Server

  # ── Content ────────────────────────────────────────────────────────

  @doc "Full text content of the buffer."
  @spec content(server()) :: String.t()
  defdelegate content(server), to: Server

  @doc "Content and cursor position in a single call (avoids two round-trips)."
  @spec content_and_cursor(server()) :: {String.t(), position()}
  defdelegate content_and_cursor(server), to: Server

  @doc "A range of lines starting at `start` (0-indexed), returning `count` lines."
  @spec lines(server(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  defdelegate lines(server, start, count), to: Server, as: :get_lines

  @doc "Content of lines from `start_line` to `end_line` (inclusive, 0-indexed)."
  @spec lines_content(server(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  defdelegate lines_content(server, start_line, end_line), to: Server, as: :get_lines_content

  @doc "Text between two positions (end exclusive)."
  @spec text_between(server(), position(), position()) :: String.t()
  defdelegate text_between(server, from_pos, to_pos), to: Server, as: :content_range

  @doc "Text between two positions (end inclusive, includes the character at end_pos)."
  @spec text_between_inclusive(server(), position(), position()) :: String.t()
  defdelegate text_between_inclusive(server, start_pos, end_pos), to: Server, as: :get_range

  @doc "Number of lines in the buffer."
  @spec line_count(server()) :: pos_integer()
  defdelegate line_count(server), to: Server

  @doc "Byte offset of the start of a line (for tree-sitter integration)."
  @spec byte_offset_for_line(server(), non_neg_integer()) :: non_neg_integer()
  defdelegate byte_offset_for_line(server, line), to: Server

  # ── Cursor ─────────────────────────────────────────────────────────

  @doc "Current cursor position as `{line, col}`."
  @spec cursor(server()) :: position()
  defdelegate cursor(server), to: Server

  @doc "Move the cursor to an exact position."
  @spec move_to(server(), position()) :: :ok
  defdelegate move_to(server, pos), to: Server

  @doc "Move the cursor one step in a direction."
  @spec move(server(), direction()) :: :ok
  defdelegate move(server, direction), to: Server

  @doc "Move cursor if possible, returning the result position and whether a boundary was hit."
  @spec move_if_possible(server(), :left | :right) ::
          {:ok, position()} | {:at_boundary, position()}
  defdelegate move_if_possible(server, direction), to: Server

  # ── Editing ────────────────────────────────────────────────────────

  @doc "Insert a single character at the cursor."
  @spec insert_char(server(), String.t(), Minga.Buffer.EditSource.t()) :: :ok
  defdelegate insert_char(server, char, source \\ Minga.Buffer.EditSource.user()), to: Server

  @doc "Insert a multi-character string at the cursor."
  @spec insert_text(server(), String.t(), Minga.Buffer.EditSource.t()) :: :ok
  defdelegate insert_text(server, text, source \\ Minga.Buffer.EditSource.user()), to: Server

  @doc "Replace text in a range with new text (the general-purpose edit operation)."
  @spec apply_edit(
          server(),
          position(),
          position(),
          String.t(),
          Minga.Buffer.EditSource.t(),
          keyword()
        ) :: :ok
  defdelegate apply_edit(server, start_pos, end_pos, new_text, source, opts \\ []),
    to: Server,
    as: :apply_text_edit

  @doc "Apply a batch of edits atomically (for LSP workspace edits)."
  @spec apply_edits(server(), [Server.text_edit()], Minga.Buffer.EditSource.t()) :: :ok
  defdelegate apply_edits(server, edits, source \\ Minga.Buffer.EditSource.lsp(:unknown)),
    to: Server,
    as: :apply_text_edits

  @doc "Delete the character before the cursor."
  @spec delete_before(server()) :: :ok
  defdelegate delete_before(server), to: Server

  @doc "Delete the character at the cursor."
  @spec delete_at(server()) :: :ok
  defdelegate delete_at(server), to: Server

  @doc "Delete text between two positions."
  @spec delete_range(server(), position(), position()) :: :ok
  defdelegate delete_range(server, from_pos, to_pos), to: Server

  @doc "Delete lines from `start_line` to `end_line` (inclusive)."
  @spec delete_lines(server(), non_neg_integer(), non_neg_integer()) :: :ok
  defdelegate delete_lines(server, start_line, end_line), to: Server

  @doc "Clear the contents of a single line."
  @spec clear_line(server(), non_neg_integer()) :: :ok
  defdelegate clear_line(server, line), to: Server

  @doc "Replace the entire buffer content."
  @spec replace_content(server(), String.t(), Minga.Buffer.State.edit_source()) ::
          :ok | {:error, term()}
  defdelegate replace_content(server, new_content, source \\ :user), to: Server

  @doc "Replace content unconditionally (bypasses read-only check)."
  @spec replace_content_force(server(), String.t()) :: :ok
  defdelegate replace_content_force(server, new_content), to: Server

  @doc "Find and replace the first occurrence of `old_text` with `new_text`."
  @spec find_and_replace(server(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  defdelegate find_and_replace(server, old_text, new_text), to: Server

  @doc "Find and replace multiple patterns atomically."
  @spec find_and_replace_batch(server(), [Server.replace_edit()]) ::
          {:ok, [{:ok, non_neg_integer()} | {:error, :not_found}]}
  defdelegate find_and_replace_batch(server, edits), to: Server

  @doc "Append text to the end of the buffer."
  @spec append(server(), String.t()) :: :ok
  defdelegate append(server, text), to: Server

  # ── Undo/Redo ──────────────────────────────────────────────────────

  @doc "Undo the last edit."
  @spec undo(server()) :: :ok | :empty
  defdelegate undo(server), to: Server

  @doc "Redo the last undone edit."
  @spec redo(server()) :: :ok | :empty
  defdelegate redo(server), to: Server

  @doc "Force the next edit to start a new undo group."
  @spec break_undo_coalescing(server()) :: :ok
  defdelegate break_undo_coalescing(server), to: Server

  # ── File persistence ───────────────────────────────────────────────

  @doc "Save the buffer to disk."
  @spec save(server()) :: :ok | {:error, term()}
  defdelegate save(server), to: Server

  @doc "Save even if the buffer appears clean."
  @spec force_save(server()) :: :ok | {:error, term()}
  defdelegate force_save(server), to: Server

  @doc "Reload content from disk, discarding unsaved changes."
  @spec reload(server()) :: :ok | {:error, term()}
  defdelegate reload(server), to: Server

  @doc "Save the buffer to a new file path."
  @spec save_as(server(), String.t()) :: :ok | {:error, term()}
  defdelegate save_as(server, file_path), to: Server

  # ── Identity and metadata ──────────────────────────────────────────

  @doc "File path of the buffer, or nil for scratch buffers."
  @spec file_path(server()) :: String.t() | nil
  defdelegate file_path(server), to: Server

  @doc "Detected filetype (e.g., `:elixir`, `:json`)."
  @spec filetype(server()) :: atom()
  defdelegate filetype(server), to: Server

  @doc "Override the detected filetype."
  @spec set_filetype(server(), atom()) :: :ok
  defdelegate set_filetype(server, filetype), to: Server

  @doc "Logical name of the buffer (e.g., `*Messages*`), or nil for file buffers."
  @spec buffer_name(server()) :: String.t() | nil
  defdelegate buffer_name(server), to: Server

  @doc "Human-readable display name (file basename or buffer name)."
  @spec display_name(server()) :: String.t()
  defdelegate display_name(server), to: Server

  @doc "Whether the buffer has unsaved changes."
  @spec dirty?(server()) :: boolean()
  defdelegate dirty?(server), to: Server

  @doc "Whether the buffer is read-only."
  @spec read_only?(server()) :: boolean()
  defdelegate read_only?(server), to: Server

  @doc "Whether the buffer is hidden from buffer lists."
  @spec unlisted?(server()) :: boolean()
  defdelegate unlisted?(server), to: Server

  @doc "Whether the buffer survives tab close (e.g., `*Messages*`)."
  @spec persistent?(server()) :: boolean()
  defdelegate persistent?(server), to: Server

  @doc "Buffer kind: `:file`, `:scratch`, or `:special`."
  @spec buffer_type(server()) :: :file | :scratch | :special
  defdelegate buffer_type(server), to: Server

  @doc "Monotonic version counter (incremented on every content change)."
  @spec version(server()) :: non_neg_integer()
  defdelegate version(server), to: Server

  # ── Per-buffer options ─────────────────────────────────────────────

  @doc "Read a per-buffer option (falls back to global config)."
  @spec get_option(server(), atom()) :: term()
  defdelegate get_option(server, name), to: Server

  @doc "Set a per-buffer option override."
  @spec set_option(server(), atom(), term()) :: :ok
  defdelegate set_option(server, name, value), to: Server

  # ── Snapshots ──────────────────────────────────────────────────────

  @doc "Capture a snapshot of the document state (for undo boundaries and tab switching)."
  @spec snapshot(server()) :: Minga.Buffer.Document.t()
  defdelegate snapshot(server), to: Server

  @doc "Restore a previously captured document snapshot."
  @spec apply_snapshot(server(), Minga.Buffer.Document.t()) :: :ok
  defdelegate apply_snapshot(server, new_buf), to: Server

  @doc "Render-ready snapshot of visible lines for the rendering pipeline."
  @spec render_snapshot(server(), non_neg_integer(), non_neg_integer()) ::
          Minga.Buffer.RenderSnapshot.t()
  defdelegate render_snapshot(server, first_line, count), to: Server

  # ── Edit deltas (for LSP incremental sync) ─────────────────────────

  @doc "Flush edit deltas accumulated since the given consumer's last read."
  @spec flush_edits(server(), atom()) :: [Minga.Buffer.EditDelta.t()]
  defdelegate flush_edits(server, consumer_id), to: Server

  # ── Decorations ────────────────────────────────────────────────────

  @doc "Current decoration state (highlights, virtual text, folds, etc.)."
  @spec decorations(server()) :: Minga.Buffer.Decorations.t()
  defdelegate decorations(server), to: Server

  @doc "Version counter for decorations (for change detection)."
  @spec decorations_version(server()) :: non_neg_integer()
  defdelegate decorations_version(server), to: Server

  @doc "Apply a batch of decoration changes atomically."
  @spec batch_decorations(server(), (Minga.Buffer.Decorations.t() -> Minga.Buffer.Decorations.t())) ::
          :ok
  defdelegate batch_decorations(server, fun), to: Server

  @doc "Replace buffer content and apply decorations in one atomic operation."
  @spec replace_content_with_decorations(server(), String.t(), function(), keyword()) :: :ok
  defdelegate replace_content_with_decorations(server, content, decoration_fn, opts \\ []),
    to: Server

  @doc "Add a highlight range."
  @spec add_highlight(server(), position(), position(), keyword()) :: non_neg_integer()
  defdelegate add_highlight(server, start_pos, end_pos, opts), to: Server

  @doc "Remove a highlight by ID."
  @spec remove_highlight(server(), non_neg_integer()) :: :ok
  defdelegate remove_highlight(server, id), to: Server

  @doc "Remove all highlights in a group."
  @spec remove_highlight_group(server(), atom()) :: :ok
  defdelegate remove_highlight_group(server, group), to: Server

  @doc "Add virtual text anchored to a line."
  @spec add_virtual_text(server(), non_neg_integer(), keyword()) :: non_neg_integer()
  defdelegate add_virtual_text(server, anchor, opts), to: Server

  @doc "Remove virtual text by ID."
  @spec remove_virtual_text(server(), non_neg_integer()) :: :ok
  defdelegate remove_virtual_text(server, id), to: Server

  @doc "Add a block decoration (multi-line annotation) anchored to a line."
  @spec add_block_decoration(server(), non_neg_integer(), keyword()) :: non_neg_integer()
  defdelegate add_block_decoration(server, anchor_line, opts), to: Server

  @doc "Remove a block decoration by ID."
  @spec remove_block_decoration(server(), non_neg_integer()) :: :ok
  defdelegate remove_block_decoration(server, id), to: Server

  # ── Face overrides (per-buffer syntax highlighting customization) ──

  @doc "Current face override map."
  @spec face_overrides(server()) :: %{String.t() => keyword()}
  defdelegate face_overrides(server), to: Server

  @doc "Override a face's attributes for this buffer."
  @spec remap_face(server(), String.t(), keyword()) :: :ok
  defdelegate remap_face(server, face_name, attrs), to: Server

  @doc "Remove a face override for this buffer."
  @spec clear_face_override(server(), String.t()) :: :ok
  defdelegate clear_face_override(server, face_name), to: Server
end
