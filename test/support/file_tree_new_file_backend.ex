defmodule Minga.Test.FileTreeNewFileBackend do
  @moduledoc "Deterministic New File backend for production input recovery tests."

  @behaviour MingaEditor.Commands.FileTree.NewFileBackend

  alias MingaEditor.Commands.FileTree.SystemNewFileBackend

  @impl true
  @spec mkdir_p(String.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(path), do: SystemNewFileBackend.mkdir_p(path)

  @impl true
  @spec touch(String.t()) :: :ok | {:error, File.posix()}
  def touch(path) do
    case Path.basename(path) do
      "permission-denied.txt" -> {:error, :eacces}
      _name -> SystemNewFileBackend.touch(path)
    end
  end

  @impl true
  @spec open_buffer(String.t(), Minga.Config.Options.server(), Minga.Events.registry()) ::
          {:ok, pid()} | {:error, term()}
  def open_buffer(path, options_server, events_registry) do
    case Path.basename(path) do
      "open-fails-" <> _suffix -> {:error, :eio}
      _name -> SystemNewFileBackend.open_buffer(path, options_server, events_registry)
    end
  end
end
