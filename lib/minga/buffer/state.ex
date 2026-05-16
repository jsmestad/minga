defmodule Minga.Buffer.State do
  @moduledoc """
  Internal state for the Buffer GenServer.

  Holds the document, file path, dirty flag, and buffer-local runtime state.
  """

  alias Minga.Buffer.ChangeLog
  alias Minga.Buffer.Document
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.UndoHistory
  alias Minga.Core.Decorations

  @default_change_log ChangeLog.new()
  @default_undo_history UndoHistory.new()

  @typedoc """
  Buffer type controlling behavior:

  * `:file`: (default) normal file buffer, supports save/dirty/undo
  * `:nofile`: no file association, implicitly read-only, no save
  * `:nowrite`: has a file path for display but cannot save
  * `:prompt`: like `:nofile` but the last line is editable (for agent input, command input)
  * `:terminal`: backed by an external process writing into the buffer
  """
  @type buffer_type :: :file | :nofile | :nowrite | :prompt | :terminal

  @typedoc "File storage backend for buffer file I/O. Remote buffers still edit locally, but open/save/stat calls route through Erlang distribution."
  @type storage :: :local | {:remote, node(), String.t()}

  @typedoc "The source of an edit for undo/redo attribution."
  @type edit_source :: EditSource.undo_source()

  @enforce_keys [:document]
  defstruct document: nil,
            file_path: nil,
            filetype: :text,
            storage: :local,
            buffer_type: :file,
            dirty: false,
            version: 0,
            saved_version: 0,
            mtime: nil,
            file_size: nil,
            file_hash: nil,
            undo_history: @default_undo_history,
            name: nil,
            read_only: false,
            unlisted: false,
            persistent: false,
            change_log: @default_change_log,
            decorations: %Decorations{},
            face_overrides: %{},
            options: %{},
            explicit_options: MapSet.new(),
            swap_timer: nil,
            auto_save_timer: nil,
            auto_save_token: nil,
            swap_dir: nil,
            events_registry: Minga.Events.default_registry()

  @type t :: %__MODULE__{
          document: Document.t(),
          file_path: String.t() | nil,
          filetype: atom(),
          storage: storage(),
          buffer_type: buffer_type(),
          dirty: boolean(),
          version: non_neg_integer(),
          saved_version: non_neg_integer(),
          mtime: integer() | nil,
          file_size: non_neg_integer() | nil,
          file_hash: binary() | nil,
          undo_history: UndoHistory.t(),
          name: String.t() | nil,
          read_only: boolean(),
          unlisted: boolean(),
          persistent: boolean(),
          change_log: ChangeLog.t(),
          decorations: Decorations.t(),
          face_overrides: %{String.t() => keyword()},
          options: %{atom() => term()},
          explicit_options: MapSet.t(atom()),
          swap_timer: reference() | nil,
          auto_save_timer: reference() | nil,
          auto_save_token: reference() | nil,
          swap_dir: String.t() | nil,
          events_registry: Minga.Events.registry()
        }

  @doc "Marks the buffer as having unsaved changes (bumps version)."
  @spec mark_dirty(t()) :: t()
  def mark_dirty(%__MODULE__{} = state) do
    new_version = state.version + 1
    %{state | dirty: new_version != state.saved_version, version: new_version}
  end

  @doc """
  Sets the dirty flag based on whether the given version matches the saved
  version. Used by undo/redo which restore a version from history rather
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
end
