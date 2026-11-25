defmodule MingaAgent.Test.Overlay.UnsupportedCloner do
  @moduledoc "Test cloner for a file system without copy-on-write support: every clone is unsupported."

  @behaviour MingaAgent.Changeset.Overlay.Cloner

  alias MingaAgent.Test.Overlay.CopyCloner

  @impl true
  @spec clone(String.t(), String.t()) :: {:error, {:unsupported, :clone_unsupported}}
  def clone(_source, _target), do: {:error, {:unsupported, :clone_unsupported}}

  @impl true
  @spec remove(String.t()) :: :ok | {:error, term()}
  defdelegate remove(path), to: CopyCloner
end
