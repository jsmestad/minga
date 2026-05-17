defmodule Minga.Buffer.State do
  @moduledoc """
  Internal state for the Buffer GenServer.

  Holds the document, file path, dirty flag, and buffer-local runtime state.
  """

  alias Minga.Buffer.ChangeLog
  alias Minga.Buffer.Document
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.SaveState
  alias Minga.Buffer.UndoHistory
  alias Minga.Core.Decorations

  @default_change_log ChangeLog.new()
  @default_save_state SaveState.new()
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
            save_state: @default_save_state,
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
          save_state: SaveState.t(),
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

  @doc "Marks the buffer as having unsaved changes and advances the mutation version."
  @spec mark_dirty(t()) :: t()
  def mark_dirty(%__MODULE__{} = state) do
    %{state | save_state: SaveState.mark_changed(state.save_state)}
  end

  @doc "Records a content change that should not by itself make a clean buffer dirty."
  @spec record_clean_change(t()) :: t()
  def record_clean_change(%__MODULE__{} = state) do
    %{state | save_state: SaveState.record_clean_change(state.save_state)}
  end

  @doc "Restores the mutation version and recalculates dirty state from the saved version."
  @spec restore_version(t(), non_neg_integer()) :: t()
  def restore_version(%__MODULE__{} = state, version) do
    %{state | save_state: SaveState.restore_version(state.save_state, version)}
  end

  @doc "Recalculates dirty state from the current mutation version and saved version."
  @spec sync_dirty(t()) :: t()
  def sync_dirty(%__MODULE__{} = state) do
    restore_version(state, version(state))
  end

  @doc "Retargets the buffer to a new file path without changing content or dirty state."
  @spec retarget_path(t(), String.t()) :: t()
  def retarget_path(%__MODULE__{} = state, file_path) when is_binary(file_path) do
    %{state | file_path: file_path}
  end

  @doc "Returns save state for content loaded from storage."
  @spec loaded_save_state(String.t() | nil, SaveState.metadata(), String.t()) :: SaveState.t()
  def loaded_save_state(path, metadata, content) do
    SaveState.loaded(path, metadata, content)
  end

  @doc "Replaces save tracking with a clean baseline for loaded content."
  @spec load_saved_content(t(), String.t() | nil, SaveState.metadata(), String.t()) :: t()
  def load_saved_content(%__MODULE__{} = state, path, metadata, content) do
    %{state | save_state: SaveState.loaded(path, metadata, content)}
  end

  @doc "Acknowledges disk metadata without changing dirty, version, or the saved content fingerprint."
  @spec acknowledge_disk_metadata(t(), SaveState.metadata()) :: t()
  def acknowledge_disk_metadata(%__MODULE__{} = state, metadata) do
    %{state | save_state: SaveState.acknowledge_disk_metadata(state.save_state, metadata)}
  end

  @doc "Returns true when the backing file differs from the saved baseline."
  @spec changed_since_saved?(
          t(),
          integer() | nil,
          non_neg_integer() | nil,
          SaveState.saved_content_status()
        ) :: boolean()
  def changed_since_saved?(%__MODULE__{} = state, disk_mtime, disk_size, status) do
    SaveState.changed_since_saved?(state.save_state, disk_mtime, disk_size, status)
  end

  @doc "Records the current version as the save point for dirty tracking."
  @spec mark_saved(t(), SaveState.metadata(), String.t()) :: t()
  def mark_saved(%__MODULE__{} = state, metadata, content) do
    %{state | save_state: SaveState.mark_saved(state.save_state, metadata, content)}
  end

  @doc "Accepts replacement content as a new saved baseline and advances the mutation version once."
  @spec accept_saved_content(t(), SaveState.metadata(), String.t()) :: t()
  def accept_saved_content(%__MODULE__{} = state, metadata, content) do
    %{state | save_state: SaveState.accept_saved_content(state.save_state, metadata, content)}
  end

  @doc "Returns whether the buffer differs from its saved version."
  @spec dirty?(t()) :: boolean()
  def dirty?(%__MODULE__{} = state), do: SaveState.dirty?(state.save_state)

  @doc "Returns the current mutation version."
  @spec version(t()) :: non_neg_integer()
  def version(%__MODULE__{} = state), do: SaveState.version(state.save_state)

  @doc "Returns the saved file mtime."
  @spec mtime(t()) :: integer() | nil
  def mtime(%__MODULE__{} = state), do: SaveState.mtime(state.save_state)

  @doc "Returns the saved file size."
  @spec file_size(t()) :: non_neg_integer() | nil
  def file_size(%__MODULE__{} = state), do: SaveState.file_size(state.save_state)

  @doc "Returns the saved content fingerprint, if one is known."
  @spec file_hash(t()) :: binary() | nil
  def file_hash(%__MODULE__{} = state), do: SaveState.file_hash(state.save_state)
end
