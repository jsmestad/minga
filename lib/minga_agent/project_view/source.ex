defmodule MingaAgent.ProjectView.Source do
  @moduledoc "A selected project-view source owner without materialized file content."

  @type owner ::
          {:disk, String.t()}
          | {:buffer, pid()}
          | {:fork, pid()}
          | {:changeset, pid(), String.t()}
  @type t :: %__MODULE__{source_id: String.t(), owner: owner()}

  @enforce_keys [:source_id, :owner]
  defstruct [:source_id, :owner]

  @doc "Selects a disk path while preserving the logical source identity."
  @spec disk(String.t(), String.t()) :: t()
  def disk(source_id, path) when is_binary(source_id) and is_binary(path),
    do: %__MODULE__{source_id: source_id, owner: {:disk, path}}

  @doc "Selects the buffer that owns an unsaved source."
  @spec buffer(String.t(), pid()) :: t()
  def buffer(source_id, pid) when is_binary(source_id) and is_pid(pid),
    do: %__MODULE__{source_id: source_id, owner: {:buffer, pid}}

  @doc "Selects the fork that owns an isolated source."
  @spec fork(String.t(), pid()) :: t()
  def fork(source_id, pid) when is_binary(source_id) and is_pid(pid),
    do: %__MODULE__{source_id: source_id, owner: {:fork, pid}}

  @doc "Selects the changeset that resolves an overlay edit or its disk source."
  @spec changeset(String.t(), pid(), String.t()) :: t()
  def changeset(source_id, pid, path)
      when is_binary(source_id) and is_pid(pid) and is_binary(path),
      do: %__MODULE__{source_id: source_id, owner: {:changeset, pid, path}}
end
