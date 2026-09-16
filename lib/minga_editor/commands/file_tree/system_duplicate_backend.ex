defmodule MingaEditor.Commands.FileTree.SystemDuplicateBackend do
  @moduledoc "Production Duplicate effects backed by the local filesystem."

  @behaviour MingaEditor.Commands.FileTree.DuplicateBackend

  @impl true
  @spec claim_destination(String.t(), MingaEditor.Commands.FileTree.DuplicateBackend.entry_type()) ::
          :ok | {:error, File.posix()}
  def claim_destination(path, :directory), do: File.mkdir(path)

  def claim_destination(path, :file) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, device} -> close_claimed_file(device)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec copy(String.t(), String.t(), MingaEditor.Commands.FileTree.DuplicateBackend.entry_type()) ::
          MingaEditor.Commands.FileTree.DuplicateBackend.copy_result()
  def copy(source, destination, :directory), do: File.cp_r(source, destination)
  def copy(source, destination, :file), do: File.cp(source, destination)

  @impl true
  @spec cleanup(String.t()) :: MingaEditor.Commands.FileTree.DuplicateBackend.cleanup_result()
  def cleanup(path), do: File.rm_rf(path)

  @spec close_claimed_file(IO.device()) :: :ok
  defp close_claimed_file(device) do
    _ = File.close(device)
    :ok
  end
end
