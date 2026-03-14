defmodule Minga.Buffer.State do
  @moduledoc """
  Internal state for the Buffer GenServer.

  Holds the gap buffer, file path, dirty flag, and undo/redo stacks.

  ## Undo coalescing

  Rapid edits (e.g., AI-driven or fast typing) that arrive within
  `@undo_coalesce_ms` of each other are grouped into a single undo entry.
  Instead of pushing a new snapshot for every mutation, the top of the undo
  stack is kept and only the document is replaced. This bounds memory usage
  under burst editing while preserving correct undo for human-speed edits.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta

  @typedoc """
  Buffer type controlling behavior:

  * `:file` — (default) normal file buffer, supports save/dirty/undo
  * `:nofile` — no file association, implicitly read-only, no save
  * `:nowrite` — has a file path for display but cannot save
  * `:prompt` — like `:nofile` but the last line is editable (for agent input, command input)
  * `:terminal` — backed by an external process writing into the buffer
  """
  @type buffer_type :: :file | :nofile | :nowrite | :prompt | :terminal

  @typedoc "An undo/redo stack entry: the document snapshot and its version at capture time."
  @type stack_entry :: {non_neg_integer(), Document.t()}

  @enforce_keys [:document]
  defstruct document: nil,
            file_path: nil,
            filetype: :text,
            buffer_type: :file,
            dirty: false,
            version: 0,
            saved_version: 0,
            mtime: nil,
            file_size: nil,
            undo_stack: [],
            redo_stack: [],
            last_undo_at: 0,
            name: nil,
            read_only: false,
            unlisted: false,
            persistent: false,
            pending_edits: [],
            decorations: %Decorations{},
            options: %{}

  @type t :: %__MODULE__{
          document: Document.t(),
          file_path: String.t() | nil,
          filetype: atom(),
          buffer_type: buffer_type(),
          dirty: boolean(),
          version: non_neg_integer(),
          saved_version: non_neg_integer(),
          mtime: integer() | nil,
          file_size: non_neg_integer() | nil,
          undo_stack: [stack_entry()],
          redo_stack: [stack_entry()],
          last_undo_at: integer(),
          name: String.t() | nil,
          read_only: boolean(),
          unlisted: boolean(),
          persistent: boolean(),
          pending_edits: [EditDelta.t()],
          decorations: Decorations.t(),
          options: %{atom() => term()}
        }

  @max_undo_stack 1000

  @doc """
  The coalescing window in milliseconds. Edits arriving within this window
  of the previous undo push are merged into the same undo entry.
  """
  @spec undo_coalesce_ms() :: pos_integer()
  def undo_coalesce_ms, do: 300

  @undo_coalesce_ms 300

  @doc "Marks the buffer as having unsaved changes (bumps version)."
  @spec mark_dirty(t()) :: t()
  def mark_dirty(%__MODULE__{} = state) do
    new_version = state.version + 1
    %{state | dirty: new_version != state.saved_version, version: new_version}
  end

  @doc """
  Sets the dirty flag based on whether the given version matches the saved
  version. Used by undo/redo which restore a version from the stack rather
  than incrementing.
  """
  @spec sync_dirty(t()) :: t()
  def sync_dirty(%__MODULE__{} = state) do
    %{state | dirty: state.version != state.saved_version}
  end

  @doc "Records the current version as the save point for dirty tracking."
  @spec mark_saved(t()) :: t()
  def mark_saved(%__MODULE__{} = state) do
    %{state | dirty: false, saved_version: state.version}
  end

  @doc """
  Pushes the current document onto the undo stack and replaces it with
  `new_buf`. Clears the redo stack. The undo stack is capped at
  #{@max_undo_stack} entries.

  If the previous undo push happened within #{@undo_coalesce_ms}ms, the
  new document replaces the current one without pushing another snapshot
  onto the stack. This coalesces rapid edits (AI, fast typing) into a
  single undo step while preserving distinct undo entries for edits
  separated by a pause.
  """
  @spec push_undo(t(), Document.t()) :: t()
  def push_undo(%__MODULE__{} = state, new_buf) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_undo_at

    push_undo(state, new_buf, now, elapsed)
  end

  # First undo ever, or enough time has passed: push a new entry.
  @spec push_undo(t(), Document.t(), integer(), integer()) :: t()
  defp push_undo(%__MODULE__{} = state, new_buf, now, elapsed)
       when state.last_undo_at == 0 or elapsed >= @undo_coalesce_ms do
    entry = {state.version, state.document}

    new_undo =
      [entry | state.undo_stack]
      |> Enum.take(@max_undo_stack)

    %{state | document: new_buf, undo_stack: new_undo, redo_stack: [], last_undo_at: now}
  end

  # Within the coalescing window: replace document, keep stack as-is.
  defp push_undo(%__MODULE__{} = state, new_buf, now, _elapsed) do
    %{state | document: new_buf, redo_stack: [], last_undo_at: now}
  end

  @doc """
  Pushes an undo entry unconditionally, bypassing time-based coalescing.

  Use this for explicit user actions (like `:replace_content`) where
  each invocation should always be a separate undo step regardless of
  timing.
  """
  @spec push_undo_force(t(), Document.t()) :: t()
  def push_undo_force(%__MODULE__{} = state, new_buf) do
    now = System.monotonic_time(:millisecond)
    entry = {state.version, state.document}

    new_undo =
      [entry | state.undo_stack]
      |> Enum.take(@max_undo_stack)

    %{state | document: new_buf, undo_stack: new_undo, redo_stack: [], last_undo_at: now}
  end

  @doc """
  Resets the coalescing timer so the next `push_undo/2` will always
  create a new undo entry. Call this at undo boundaries (e.g., mode
  transitions like leaving insert mode).
  """
  @spec break_undo_coalescing(t()) :: t()
  def break_undo_coalescing(%__MODULE__{} = state) do
    %{state | last_undo_at: 0}
  end
end
