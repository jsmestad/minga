defmodule MingaAgent.NotifierTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Options
  alias MingaAgent.Notifier

  defmodule Inbox do
    @behaviour MingaAgent.Notifier.OSAdapter

    @impl true
    def send_notification(title, message) do
      send(self(), {:notification, title, message})
      :ok
    end
  end

  @notify_opts [bell: false, os_adapter: Inbox]

  setup do
    options = start_supervised!({Options, name: nil})
    Process.put(:minga_config_options, options)
    %{options: options}
  end

  test "repeated completions do not silence approvals or failures" do
    Notifier.notify(:complete, "First result", @notify_opts)
    Notifier.notify(:complete, "Repeated result", @notify_opts)
    Notifier.notify(:approval, "Review first tool", @notify_opts)
    Notifier.notify(:approval, "Review second tool", @notify_opts)
    Notifier.notify(:error, "Failed turn", @notify_opts)

    assert_received {:notification, _, "First result"}
    assert_received {:notification, _, "Review first tool"}
    assert_received {:notification, _, "Review second tool"}
    assert_received {:notification, _, "Failed turn"}
    refute_received {:notification, _, "Repeated result"}
  end

  test "configured trigger filters and the master switch prevent delivery", %{options: options} do
    Options.set(options, :agent_notify_on, [:approval])
    Notifier.notify(:complete, "Filtered", @notify_opts)
    Notifier.notify(:approval, "Allowed", @notify_opts)

    Options.set(options, :agent_notifications, false)
    Notifier.notify(:approval, "Disabled", @notify_opts)

    assert_received {:notification, _, "Allowed"}
    refute_received {:notification, _, _}
  end
end
