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

  Supports three notification channels:
  1. **Terminal bell** — sends BEL character to trigger terminal tab flash
  2. **OS notification** — uses `osascript` on macOS for system notifications
  3. **Terminal title** — updates window title with attention prefix

  Notifications are debounced (at most one every 5 seconds) and can be
  disabled or filtered by trigger type via config options.

  ## Configuration

      set :agent_notifications, true           # master switch (default: true)
      set :agent_notify_on, [:approval, :complete, :error]  # which events trigger
  """

  @typedoc "Notification trigger types."
  @type trigger :: :approval | :complete | :error

  @debounce_ms 5_000

  @os_adapter Application.compile_env(
                :minga,
                :os_notify_adapter,
                MingaAgent.Notifier.OSAdapter.MacOS
              )

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Sends a notification for the given trigger if enabled and not debounced.

  `message` is a short summary shown in the OS notification body.
  """
  @spec notify(trigger(), String.t(), keyword()) :: :ok
  def notify(trigger, message, opts \\ []) do
    if enabled?() and trigger in active_triggers() and not debounced?() do
      record_notification()
      maybe_send_bell(Keyword.get(opts, :bell, true))
      send_os_notification(trigger, message, Keyword.get(opts, :os_adapter, @os_adapter))
    end

    :ok
  end

  @doc """
  Clears attention indicators (e.g., when user focuses the agent panel).

  Tab bar badge and terminal title prefix are cleared automatically by
  `EditorState.switch_tab/2` when the user switches to the agent tab.
  This function resets the debounce timer so new notifications can fire
  immediately after the user returns.
  """
  @spec clear_attention() :: :ok
  def clear_attention do
    Process.delete(:last_notification_at)
    :ok
  end

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
      _ -> [:approval, :complete, :error]
    end
  end

  @spec debounced?() :: boolean()
  defp debounced? do
    case Process.get(:last_notification_at) do
      nil -> false
      last -> System.monotonic_time(:millisecond) - last < @debounce_ms
    end
  end

  @spec record_notification() :: :ok
  defp record_notification do
    Process.put(:last_notification_at, System.monotonic_time(:millisecond))
    :ok
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

  @spec send_os_notification(trigger(), String.t(), module()) :: :ok
  defp send_os_notification(trigger, message, os_adapter) do
    title = title_for(trigger)
    os_adapter.send_notification(title, message)
  end

  @spec title_for(trigger()) :: String.t()
  defp title_for(trigger) do
    case trigger do
      :approval -> "Minga: Approval Needed"
      :complete -> "Minga: Agent Finished"
      :error -> "Minga: Agent Error"
    end
  end
end
