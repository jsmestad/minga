defmodule MingaAgent.Notifier.OSAdapter do
  @moduledoc false
  @callback send_notification(title :: String.t(), message :: String.t()) :: :ok
end

defmodule MingaAgent.Notifier.OSAdapter.MacOS do
  @moduledoc false
  @behaviour MingaAgent.Notifier.OSAdapter

  @spec send_notification(String.t(), String.t()) :: :ok
  def send_notification(title, message) do
    spawn(fn ->
      System.cmd("osascript", [
        "-e",
        ~s(display notification "#{escape(message)}" with title "#{escape(title)}")
      ])
    end)

    :ok
  rescue
    e ->
      Minga.Log.debug(:agent, "OS notification failed: #{Exception.message(e)}")
      :ok
  end

  @spec escape(String.t()) :: String.t()
  defp escape(text) do
    text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.slice(0, 200)
  end
end

defmodule MingaAgent.Notifier.OSAdapter.Noop do
  @moduledoc false
  @behaviour MingaAgent.Notifier.OSAdapter

  @spec send_notification(String.t(), String.t()) :: :ok
  def send_notification(_title, _message), do: :ok
end

defmodule MingaAgent.Notifier do
  @moduledoc """
  Sends OS-level notifications when the agent needs user attention.

  The native app receives only the event kind. Terminal sessions keep the bell and send a desktop notification through the OS adapter for the running system: `osascript` on macOS, `notify-send` on Linux.

  Completion and failure are debounced independently. Approval requests bypass the debounce because the agent cannot continue without an answer.

  ## Configuration

      set :agent_notifications, true           # master switch (default: true)
      set :agent_notify_on, [:approval, :complete, :error]  # which events trigger
  """

  @typedoc "Notification trigger types."
  @type trigger :: :approval | :complete | :error

  @triggers [:approval, :complete, :error]

  # A configured adapter (the test suite's Noop) wins. Otherwise the running OS decides; a compile-time default put the
  # macOS adapter into the Linux release.
  @configured_os_adapter Application.compile_env(:minga, :os_notify_adapter)

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Sends a notification for the given trigger if enabled and not debounced.

  External notifications use fixed text for each trigger. Session details stay in the editor.
  """
  @spec notify(trigger(), String.t(), keyword()) :: :ok
  def notify(trigger, _message, opts \\ []) do
    if trigger in @triggers and enabled?() and trigger in active_triggers() do
      deliver(Application.get_env(:minga, :backend, :tui), trigger, opts)
    end

    :ok
  end

  @doc "Withdraws this session's native approval notification after the request is retired."
  @spec clear_approval() :: :ok
  def clear_approval do
    case Process.delete({__MODULE__, :approval_id}) do
      nil -> :ok
      id -> publish(:approval_cleared, id)
    end
  end

  @doc "Resets this process's completion and failure debounce timers."
  @spec clear_attention() :: :ok
  def clear_attention do
    Process.delete({__MODULE__, :complete})
    Process.delete({__MODULE__, :error})
    :ok
  end

  @doc "Returns the OS notification adapter for an `:os.type/0` result."
  @spec os_adapter_for({atom(), atom()}) :: module()
  def os_adapter_for({:unix, :darwin}), do: MingaAgent.Notifier.OSAdapter.MacOS
  def os_adapter_for({:unix, :linux}), do: MingaAgent.Notifier.OSAdapter.Linux
  def os_adapter_for(_os_type), do: MingaAgent.Notifier.OSAdapter.Noop

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec enabled?() :: boolean()
  defp enabled? do
    case Minga.Config.get(:agent_notifications) do
      false -> false
      _ -> true
    end
  end

  @spec active_triggers() :: [trigger()]
  defp active_triggers do
    case Minga.Config.get(:agent_notify_on) do
      triggers when is_list(triggers) -> triggers
      _ -> @triggers
    end
  end

  @spec debounced?(trigger()) :: boolean()
  defp debounced?(:approval), do: false

  defp debounced?(trigger) do
    now = System.monotonic_time(:millisecond)
    debounce_ms = Minga.Config.get(:agent_notify_debounce)
    key = {__MODULE__, trigger}

    case Process.get(key) do
      last when is_integer(last) and now - last < debounce_ms ->
        true

      _ ->
        Process.put(key, now)
        false
    end
  end

  @spec deliver(atom(), trigger(), keyword()) :: :ok
  defp deliver(:gui, :approval, _opts) do
    clear_approval()
    id = :crypto.strong_rand_bytes(16)
    Process.put({__MODULE__, :approval_id}, id)
    publish(:approval, id)
  end

  defp deliver(:gui, trigger, _opts) do
    key = {__MODULE__, :session_key}
    id = Process.get(key) || new_session_key(key)
    publish(trigger, id, min(Minga.Config.get(:agent_notify_debounce), 0xFFFFFFFF))
  end

  defp deliver(_backend, trigger, opts) do
    unless debounced?(trigger) do
      maybe_send_bell(Keyword.get(opts, :bell, true))
      send_os_notification(trigger, Keyword.get_lazy(opts, :os_adapter, &os_adapter/0))
    end

    :ok
  end

  @spec os_adapter() :: module()
  defp os_adapter, do: @configured_os_adapter || os_adapter_for(:os.type())

  @spec new_session_key({module(), :session_key}) :: <<_::128>>
  defp new_session_key(key) do
    id = :crypto.strong_rand_bytes(16)
    Process.put(key, id)
    id
  end

  @spec publish(trigger() | :approval_cleared, binary(), non_neg_integer()) :: :ok
  defp publish(kind, id, debounce_ms \\ 0) do
    Minga.Events.broadcast(:agent_desktop_notification, %{
      kind: kind,
      id: id,
      owner: self(),
      debounce_ms: debounce_ms
    })
  end

  @spec maybe_send_bell(boolean()) :: :ok
  defp maybe_send_bell(false), do: :ok
  defp maybe_send_bell(true), do: send_bell()

  @spec send_bell() :: :ok
  defp send_bell do
    # Write BEL to stderr (the terminal) to trigger tab flash / dock bounce
    IO.write(:stderr, "\a")
    :ok
  rescue
    e ->
      Minga.Log.debug(:agent, "Bell notification failed: #{Exception.message(e)}")
      :ok
  end

  @spec send_os_notification(trigger(), module()) :: :ok
  defp send_os_notification(:approval, adapter),
    do: adapter.send_notification("Minga: Approval Needed", "Review the tool request in Minga.")

  defp send_os_notification(:complete, adapter),
    do: adapter.send_notification("Minga: Agent Finished", "Review the result in Minga.")

  defp send_os_notification(:error, adapter),
    do: adapter.send_notification("Minga: Agent Error", "Open the conversation for details.")
end
