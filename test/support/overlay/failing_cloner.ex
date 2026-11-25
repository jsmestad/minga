defmodule MingaAgent.Test.Overlay.FailingCloner do
  @moduledoc "Test cloner whose every clone fails for a reason other than missing copy-on-write support."

  @behaviour MingaAgent.Changeset.Overlay.Cloner

  alias MingaAgent.Test.Overlay.CopyCloner

  @impl true
  @spec clone(String.t(), String.t()) :: {:error, :eacces}
  def clone(_source, _target), do: {:error, :eacces}

  @impl true
  @spec remove(String.t()) :: :ok | {:error, term()}
  defdelegate remove(path), to: CopyCloner
end
