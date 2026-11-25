defmodule MingaAgent.Notifier.OSAdapter do
  @moduledoc """
  Sends one desktop notification through the operating system, for a terminal session that asked for desktop alerts (`:agent_notify_terminal`).

  An implementation returns at once and does its work in another process, so the editor that asked for the alert never waits on an OS command.
  """

  @callback send_notification(title :: String.t(), message :: String.t()) :: :ok
end
