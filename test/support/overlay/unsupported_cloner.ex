defmodule MingaAgent.Test.Overlay.UnsupportedCloner do
  @moduledoc "Test cloner for a filesystem without copy-on-write support: every clone fails."

  @behaviour MingaAgent.Changeset.Overlay.Cloner

  alias MingaAgent.Test.Overlay.CopyCloner

  @impl true
  @spec clone(String.t(), String.t()) :: {:error, :clone_unsupported}
  def clone(_source, _target), do: {:error, :clone_unsupported}

  @impl true
  @spec remove(String.t()) :: :ok | {:error, term()}
  defdelegate remove(path), to: CopyCloner
end
