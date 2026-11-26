defmodule MingaAgent.Notifier do
  @moduledoc """
  Posts the "a task needs you" alert for the editor, and withdraws it.

  The editor decides when to alert: a task has just started needing you (an approval or a question became pending) while Minga is in the background. See `MingaEditor.Agent.TaskWorkflow`. This module decides how, from the configuration:

  - The macOS app posts a native notification. The alert is published on `:agent_desktop_notification` with the task's session as its owner, and the frontend manager writes it to the app. A withdrawal removes it.
  - The terminal frontend alerts only when `:agent_notify_terminal` asks for it. The default is `:off`. `:bell` rings the terminal bell: the alert goes to the Go frontend, which writes the bell to its terminal. `:desktop` sends a desktop notification through the OS adapter for the running system (`osascript` on macOS, `notify-send` on Linux). `:bell_and_desktop` does both.
  - `set :agent_notifications, false` turns every alert off.

  Alerts use fixed words, so no project, command or conversation detail leaves Minga. Each call is cheap for the editor: an event broadcast, or an OS command started in another process.

  ## Configuration

      set :agent_notifications, true      # master switch (default: true)
      set :agent_notify_terminal, :bell   # terminal: :off (default), :bell, :desktop or :bell_and_desktop
  """

  alias Minga.Config.Options

  @typedoc "An alert's opaque identity: the macOS notification it posts, and what a click on it sends back."
  @type id :: <<_::128>>

  @typedoc "The kind of frontend Minga runs in: the native macOS app, or the terminal."
  @type frontend :: :native | :terminal

  @typedoc """
  Options for `needs_you/3` and `withdraw/3`.

  `:frontend` is required by `needs_you/3`. `:options` is the options server to read (default: the global one), `:registry` the event registry to publish on (default: the global bus), and `:os_adapter` the desktop notifier (default: the one for the running system).
  """
  @type opt ::
          {:frontend, frontend()}
          | {:options, Options.server()}
          | {:registry, Minga.Events.registry()}
          | {:os_adapter, module()}

  @title "Minga needs you"
  @message "A task is waiting for your answer."

  # A configured adapter (the test suite's Noop) wins. Otherwise the running OS decides; a compile-time default put the
  # macOS adapter into the Linux release.
  @configured_os_adapter Application.compile_env(:minga, :os_notify_adapter)

  @doc """
  Alerts that the task of `session` needs you, under identity `id`.

  Returns `:posted` when an alert went out, or `:off` when the configuration turned it off. Only a posted alert has anything to withdraw.
  """
  @spec needs_you(pid(), id(), [opt()]) :: :posted | :off
  def needs_you(session, <<_::128>> = id, opts) when is_pid(session) and is_list(opts) do
    options = Keyword.get(opts, :options, Options.default_server())

    case Options.get(options, :agent_notifications) do
      false ->
        :off

      _enabled ->
        terminal = Options.get(options, :agent_notify_terminal)
        deliver(Keyword.fetch!(opts, :frontend), terminal, session, id, opts)
    end
  end

  @doc "Withdraws the alert `id` posted for the task of `session`, because the task no longer needs you."
  @spec withdraw(pid(), id(), [opt()]) :: :ok
  def withdraw(session, <<_::128>> = id, opts) when is_pid(session) and is_list(opts),
    do: publish(:withdrawn, session, id, opts)

  @doc "Returns the OS notification adapter for an `:os.type/0` result."
  @spec os_adapter_for({atom(), atom()}) :: module()
  def os_adapter_for({:unix, :darwin}), do: MingaAgent.Notifier.OSAdapter.MacOS
  def os_adapter_for({:unix, :linux}), do: MingaAgent.Notifier.OSAdapter.Linux
  def os_adapter_for(_os_type), do: MingaAgent.Notifier.OSAdapter.Noop

  @spec deliver(frontend(), atom(), pid(), id(), [opt()]) :: :posted | :off
  defp deliver(:native, _terminal, session, id, opts), do: post(session, id, opts)
  defp deliver(:terminal, :bell, session, id, opts), do: post(session, id, opts)
  defp deliver(:terminal, :desktop, _session, _id, opts), do: desktop(opts)

  defp deliver(:terminal, :bell_and_desktop, session, id, opts) do
    :posted = desktop(opts)
    post(session, id, opts)
  end

  defp deliver(:terminal, _off, _session, _id, _opts), do: :off

  @spec post(pid(), id(), [opt()]) :: :posted
  defp post(session, id, opts) do
    :ok = publish(:needs_you, session, id, opts)
    :posted
  end

  @spec desktop([opt()]) :: :posted
  defp desktop(opts) do
    adapter = Keyword.get_lazy(opts, :os_adapter, &os_adapter/0)
    :ok = adapter.send_notification(@title, @message)
    :posted
  end

  @spec os_adapter() :: module()
  defp os_adapter, do: @configured_os_adapter || os_adapter_for(:os.type())

  @spec publish(:needs_you | :withdrawn, pid(), id(), [opt()]) :: :ok
  defp publish(kind, session, id, opts) do
    Minga.Events.broadcast(
      :agent_desktop_notification,
      %{kind: kind, id: id, owner: session},
      Keyword.get(opts, :registry, Minga.Events.default_registry())
    )
  end
end
