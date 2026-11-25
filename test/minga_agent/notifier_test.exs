defmodule MingaAgent.NotifierTest do
  @moduledoc """
  The notifier turns the editor's "a task needs you" decision into an alert: a native notification, a terminal bell or a desktop notification, from the configuration. Nothing else alerts.
  """

  use ExUnit.Case, async: true

  alias Minga.Config.Options
  alias MingaAgent.Notifier

  defmodule Inbox do
    @behaviour MingaAgent.Notifier.OSAdapter

    @impl true
    def send_notification(title, message) do
      send(self(), {:desktop, title, message})
      :ok
    end
  end

  @id <<9::128>>

  setup do
    id = System.unique_integer([:positive])
    registry = :"notifier_test_events_#{id}"
    start_supervised!({Minga.Events, name: registry}, id: {:events, id})
    Minga.Events.subscribe(:agent_desktop_notification, registry: registry)
    options = start_supervised!({Options, name: nil}, id: {:options, id})
    %{registry: registry, options: options}
  end

  defp opts(ctx, frontend),
    do: [frontend: frontend, options: ctx.options, registry: ctx.registry, os_adapter: Inbox]

  test "the macOS app gets the alert with its session as owner, and its withdrawal", ctx do
    session = self()

    assert Notifier.needs_you(session, @id, opts(ctx, :native)) == :posted

    assert_received {:minga_event, :agent_desktop_notification,
                     %{kind: :needs_you, id: @id, owner: ^session}}

    refute_received {:desktop, _title, _message}

    assert Notifier.withdraw(session, @id, opts(ctx, :native)) == :ok

    assert_received {:minga_event, :agent_desktop_notification,
                     %{kind: :withdrawn, id: @id, owner: ^session}}
  end

  test "the terminal alerts only as :agent_notify_terminal says, and is off by default", ctx do
    assert Options.get(ctx.options, :agent_notify_terminal) == :off

    cases = [
      {:off, :off, false, false},
      {:bell, :posted, true, false},
      {:desktop, :posted, false, true},
      {:bell_and_desktop, :posted, true, true}
    ]

    for {setting, result, bell?, desktop?} <- cases do
      {:ok, _} = Options.set(ctx.options, :agent_notify_terminal, setting)

      assert Notifier.needs_you(self(), @id, opts(ctx, :terminal)) == result

      if bell? do
        assert_received {:minga_event, :agent_desktop_notification, %{kind: :needs_you}}
      else
        refute_received {:minga_event, :agent_desktop_notification, _alert}
      end

      if desktop? do
        assert_received {:desktop, "Minga needs you", message}
        refute message =~ "/"
      else
        refute_received {:desktop, _title, _message}
      end
    end
  end

  test "the master switch turns every alert off", ctx do
    {:ok, _} = Options.set(ctx.options, :agent_notify_terminal, :bell_and_desktop)
    {:ok, _} = Options.set(ctx.options, :agent_notifications, false)

    for frontend <- [:native, :terminal] do
      assert Notifier.needs_you(self(), @id, opts(ctx, frontend)) == :off
    end

    refute_received {:minga_event, :agent_desktop_notification, _alert}
    refute_received {:desktop, _title, _message}
  end

  test "completion and failure alerts are gone, with their options", ctx do
    refute function_exported?(Notifier, :notify, 3)

    for removed <- [:agent_notify_on, :agent_notify_debounce] do
      assert Options.type_for(removed) == nil
      assert {:error, _reason} = Options.set(ctx.options, removed, [:approval])
    end
  end

  test "terminal sessions notify through the adapter for the running OS" do
    assert Notifier.os_adapter_for({:unix, :darwin}) == MingaAgent.Notifier.OSAdapter.MacOS
    assert Notifier.os_adapter_for({:unix, :linux}) == MingaAgent.Notifier.OSAdapter.Linux

    for other <- [{:unix, :freebsd}, {:win32, :nt}] do
      assert Notifier.os_adapter_for(other) == MingaAgent.Notifier.OSAdapter.Noop
    end
  end
end
