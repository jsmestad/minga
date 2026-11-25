defmodule MingaAgent.Notifier.OSAdapter.Noop do
  @moduledoc "Sends nothing: for systems without a supported notifier, and for the test suite."

  @behaviour MingaAgent.Notifier.OSAdapter

  @impl true
  @spec send_notification(String.t(), String.t()) :: :ok
  def send_notification(_title, _message), do: :ok
end
