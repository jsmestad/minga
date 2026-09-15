defmodule MingaEditor.Commands.FileTree.NewFileBackend do
  @moduledoc """
  Injectable boundary for the New File command's fallible effects.

  The command owns operation ordering and editor-state transitions. A backend only performs the requested filesystem or buffer operation so failures remain deterministic in tests.
  """

  @type t :: module()

  @callback mkdir_p(String.t()) :: :ok | {:error, File.posix()}
  @callback touch(String.t()) :: :ok | {:error, File.posix()}
  @callback open_buffer(String.t(), Minga.Config.Options.server(), Minga.Events.registry()) ::
              {:ok, pid()} | {:error, term()}
end
