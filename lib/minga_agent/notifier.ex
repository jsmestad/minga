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

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Sends a notification for the given trigger if enabled and not debounced.

  `message` is a short summary shown in the OS notification body.
  """
  @spec notify(trigger(), String.t()) :: :ok
  def notify(trigger, message) do
    if enabled?() and trigger in active_triggers() and not debounced?() do
      record_notification()
      send_bell()
      send_os_notification(trigger, message)
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

  @spec send_os_notification(trigger(), String.t()) :: :ok
  defp send_os_notification(trigger, message) do
    title =
      case trigger do
        :approval -> "Minga: Approval Needed"
        :complete -> "Minga: Agent Finished"
        :error -> "Minga: Agent Error"
      end

    # macOS: use osascript for native notifications.
    # Falls back silently on non-macOS.
    spawn(fn ->
      System.cmd("osascript", [
        "-e",
        ~s(display notification "#{escape_applescript(message)}" with title "#{escape_applescript(title)}")
      ])
    end)

    :ok
  rescue
    e ->
      Minga.Log.debug(:agent, "OS notification failed: #{Exception.message(e)}")
      :ok
  end

  @spec escape_applescript(String.t()) :: String.t()
  defp escape_applescript(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.slice(0, 200)
  end
end
