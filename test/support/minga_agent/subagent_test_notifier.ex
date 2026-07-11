defmodule Minga.Test.SubagentTestNotifier do
  @moduledoc false

  @spec notify(atom(), String.t(), pid()) :: :ok
  def notify(trigger, message, test_pid) do
    send(test_pid, {:notified, trigger, message})
    :ok
  end
end
