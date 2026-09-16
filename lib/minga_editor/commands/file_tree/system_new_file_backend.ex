defmodule MingaEditor.Commands.FileTree.SystemNewFileBackend do
  @moduledoc "Production New File effects backed by the local filesystem and buffer registry."

  @behaviour MingaEditor.Commands.FileTree.NewFileBackend

  alias MingaEditor.Commands

  @impl true
  @spec mkdir_p(String.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(path), do: File.mkdir_p(path)

  @impl true
  @spec touch(String.t()) :: :ok | {:error, File.posix()}
  def touch(path), do: File.touch(path)

  @impl true
  @spec open_buffer(String.t(), Minga.Config.Options.server(), Minga.Events.registry()) ::
          {:ok, pid()} | {:error, term()}
  def open_buffer(path, options_server, events_registry) do
    Commands.start_buffer(path, options_server, events_registry: events_registry)
  end
end
