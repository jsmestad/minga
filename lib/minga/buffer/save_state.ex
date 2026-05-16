defmodule Minga.Buffer.SaveState do
  @moduledoc """
  Tracks whether a buffer has diverged from its last saved baseline.

  This module owns the pure save-point model: mutation versions, the saved version, dirty calculation, and the saved file fingerprint used by persistence conflict checks. It does not read or write files; `Minga.Buffer.Persistence` still owns storage I/O.
  """

  @type metadata :: {mtime :: integer() | nil, size :: non_neg_integer() | nil}
  @type saved_content_status :: :same | :changed | :unknown

  @opaque t :: %__MODULE__{
            dirty: boolean(),
            version: non_neg_integer(),
            saved_version: non_neg_integer(),
            mtime: integer() | nil,
            file_size: non_neg_integer() | nil,
            file_hash: binary() | nil
          }

  defstruct dirty: false,
            version: 0,
            saved_version: 0,
            mtime: nil,
            file_size: nil,
            file_hash: nil

  @doc "Returns a clean save state for a new buffer with no saved file baseline."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns a clean save state for content loaded from storage."
  @spec loaded(String.t() | nil, metadata(), String.t()) :: t()
  def loaded(path, {mtime, file_size}, content) do
    %__MODULE__{
      mtime: mtime,
      file_size: file_size,
      file_hash: saved_content_fingerprint(path, mtime, content)
    }
  end

  @doc "Marks the buffer as changed and advances the mutation version."
  @spec mark_changed(t()) :: t()
  def mark_changed(%__MODULE__{} = save_state) do
    new_version = save_state.version + 1
    %{save_state | dirty: new_version != save_state.saved_version, version: new_version}
  end

  @doc "Records a content change that should not by itself make a clean buffer dirty."
  @spec record_clean_change(t()) :: t()
  def record_clean_change(%__MODULE__{dirty: true} = save_state) do
    %{save_state | version: save_state.version + 1}
  end

  def record_clean_change(%__MODULE__{} = save_state) do
    new_version = save_state.version + 1
    %{save_state | version: new_version, saved_version: new_version}
  end

  @doc "Restores the mutation version and recalculates dirty state from the saved version."
  @spec restore_version(t(), non_neg_integer()) :: t()
  def restore_version(%__MODULE__{} = save_state, version)
      when is_integer(version) and version >= 0 do
    %{save_state | version: version, dirty: version != save_state.saved_version}
  end

  @doc "Acknowledges the latest disk metadata while preserving the saved content fingerprint."
  @spec acknowledge_disk_metadata(t(), metadata()) :: t()
  def acknowledge_disk_metadata(%__MODULE__{} = save_state, {mtime, file_size}) do
    %{save_state | mtime: mtime, file_size: file_size}
  end

  @doc "Records the current version as the saved baseline."
  @spec mark_saved(t(), metadata(), String.t()) :: t()
  def mark_saved(%__MODULE__{} = save_state, {mtime, file_size}, content) do
    %{
      save_state
      | dirty: false,
        saved_version: save_state.version,
        mtime: mtime,
        file_size: file_size,
        file_hash: content_fingerprint(content)
    }
  end

  @doc "Accepts replacement content as a new saved baseline and advances the mutation version once."
  @spec accept_saved_content(t(), metadata(), String.t()) :: t()
  def accept_saved_content(%__MODULE__{} = save_state, {mtime, file_size}, content) do
    new_version = save_state.version + 1

    %{
      save_state
      | dirty: false,
        version: new_version,
        saved_version: new_version,
        mtime: mtime,
        file_size: file_size,
        file_hash: content_fingerprint(content)
    }
  end

  @doc "Returns true when the backing file differs from the saved baseline."
  @spec changed_since_saved?(
          t(),
          integer() | nil,
          non_neg_integer() | nil,
          saved_content_status()
        ) :: boolean()
  def changed_since_saved?(%__MODULE__{mtime: nil}, nil, _disk_size, _status), do: false
  def changed_since_saved?(%__MODULE__{mtime: nil}, _disk_mtime, _disk_size, _status), do: true
  def changed_since_saved?(_save_state, nil, _disk_size, _status), do: false

  def changed_since_saved?(%__MODULE__{} = save_state, disk_mtime, disk_size, status) do
    metadata_changed? = disk_mtime != save_state.mtime or disk_size != save_state.file_size

    case status do
      :same -> false
      :changed -> true
      :unknown -> metadata_changed?
    end
  end

  @doc "Returns whether the buffer differs from its saved version."
  @spec dirty?(t()) :: boolean()
  def dirty?(%__MODULE__{} = save_state), do: save_state.dirty

  @doc "Returns the current mutation version."
  @spec version(t()) :: non_neg_integer()
  def version(%__MODULE__{} = save_state), do: save_state.version

  @doc "Returns the saved baseline version."
  @spec saved_version(t()) :: non_neg_integer()
  def saved_version(%__MODULE__{} = save_state), do: save_state.saved_version

  @doc "Returns the saved file mtime."
  @spec mtime(t()) :: integer() | nil
  def mtime(%__MODULE__{} = save_state), do: save_state.mtime

  @doc "Returns the saved file size."
  @spec file_size(t()) :: non_neg_integer() | nil
  def file_size(%__MODULE__{} = save_state), do: save_state.file_size

  @doc "Returns the saved content fingerprint, if one is known."
  @spec file_hash(t()) :: binary() | nil
  def file_hash(%__MODULE__{} = save_state), do: save_state.file_hash

  @doc "Fingerprints content with the algorithm used to track saved file baselines."
  @spec content_fingerprint(String.t()) :: binary()
  def content_fingerprint(content), do: :crypto.hash(:sha256, content)

  @doc "Returns a saved-content fingerprint only when a path and concrete mtime make the baseline meaningful."
  @spec saved_content_fingerprint(String.t() | nil, integer() | nil, String.t()) :: binary() | nil
  def saved_content_fingerprint(path, mtime, content)
      when is_binary(path) and is_integer(mtime) do
    content_fingerprint(content)
  end

  def saved_content_fingerprint(_path, _mtime, _content), do: nil
end
