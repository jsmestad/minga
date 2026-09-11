defmodule MingaEditor.NativeIPC.RuntimeEntry do
  @moduledoc "Security validation for native IPC runtime files and directories."

  import Bitwise

  @doc "Validates a runtime entry's type, owner, and exact Unix permission bits."
  @spec validate_private(String.t(), atom(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def validate_private(path, expected_type, euid, permissions) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^expected_type, uid: ^euid, mode: mode}}
      when (mode &&& 0o777) == permissions ->
        :ok

      {:ok, %File.Stat{} = stat} ->
        {:error, {:insecure_runtime_entry, path, stat.type, stat.uid, stat.mode &&& 0o777}}

      {:error, reason} ->
        {:error, {:runtime_entry, path, reason}}
    end
  end
end
