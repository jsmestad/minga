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

  test "external alerts keep session details private without silencing other triggers", %{
    options: options
  } do
    Options.set(options, :agent_notify_debounce, 120_000)
    private_detail = "private-project-marker"

    Notifier.notify(:complete, "First result: #{private_detail}", @notify_opts)
    assert_received {:notification, "Minga: Agent Finished", body}
    refute body =~ private_detail

    Notifier.notify(:complete, "Repeated result: #{private_detail}", @notify_opts)
    refute_received {:notification, _, _}

    for summary <- ["Review first tool", "Review second tool"] do
      Notifier.notify(:approval, "#{summary}: #{private_detail}", @notify_opts)
      assert_received {:notification, "Minga: Approval Needed", body}
      refute body =~ private_detail
      refute_received {:notification, _, _}
    end

    Notifier.notify(:error, "Failed turn: #{private_detail}", @notify_opts)
    assert_received {:notification, "Minga: Agent Error", body}
    refute body =~ private_detail
    refute_received {:notification, _, _}
  end

  test "terminal sessions notify through the adapter for the running OS" do
    assert Notifier.os_adapter_for({:unix, :darwin}) == MingaAgent.Notifier.OSAdapter.MacOS
    assert Notifier.os_adapter_for({:unix, :linux}) == MingaAgent.Notifier.OSAdapter.Linux

    for other <- [{:unix, :freebsd}, {:win32, :nt}] do
      assert Notifier.os_adapter_for(other) == MingaAgent.Notifier.OSAdapter.Noop
    end
  end

  test "configured trigger filters and the master switch prevent delivery", %{options: options} do
    Options.set(options, :agent_notify_on, [:approval])
    Notifier.notify(:complete, "Filtered", @notify_opts)
    refute_received {:notification, _, _}

    Notifier.notify(:approval, "Allowed", @notify_opts)
    assert_received {:notification, "Minga: Approval Needed", _}
    refute_received {:notification, _, _}

    Options.set(options, :agent_notifications, false)
    Notifier.notify(:approval, "Disabled", @notify_opts)
    refute_received {:notification, _, _}
  end
end
