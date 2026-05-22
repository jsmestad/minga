defmodule MingaEditor.Handlers.Notifications do
  @moduledoc """
  Notification helpers: building, displaying, and auto-dismissing editor notifications.

  Changes when: notification presentation, scheduling, or lifecycle logic changes.
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Notification

  @typedoc "Editor state (same as `MingaEditor.state()`)."
  @type state :: EditorState.t()

  @doc false
  @spec update_test_notification(state(), non_neg_integer()) :: state()
  def update_test_notification(state, 0) do
    put_notification(
      state,
      Notification.new(
        id: "build:test",
        level: :success,
        title: "Build finished",
        body: "Tests passed",
        source: "Build",
        auto_dismiss_ms: 4_000
      )
    )
  end

  def update_test_notification(state, exit_code) do
    put_notification(
      state,
      Notification.new(
        id: "build:test",
        level: :error,
        title: "Build failed",
        body: "Test command exited with code #{exit_code}",
        source: "Build",
        actions: [
          %{id: "show_logs", label: "Show logs", dispatch: {:command, :test_output}},
          %{id: "retry", label: "Retry", dispatch: {:command, :test_rerun}}
        ]
      )
    )
  end

  # ── Private helpers ──────────────────────────────────────────────────

  @spec put_notification(state(), Notification.t()) :: state()
  defp put_notification(state, %Notification{} = notification) do
    notification = maybe_schedule_notification_dismiss(notification, state.backend)

    state
    |> log_notification(notification)
    |> EditorState.upsert_notification(notification)
  end

  @spec maybe_schedule_notification_dismiss(Notification.t(), EditorState.backend()) ::
          Notification.t()
  defp maybe_schedule_notification_dismiss(
         %Notification{auto_dismiss_ms: ms, id: id} = notification,
         backend
       )
       when is_integer(ms) and ms > 0 and backend != :headless do
    dismiss_ref = make_ref()
    Process.send_after(self(), {:dismiss_notification, id, dismiss_ref}, ms)
    Notification.with_dismiss_ref(notification, dismiss_ref)
  end

  defp maybe_schedule_notification_dismiss(%Notification{} = notification, _backend),
    do: notification

  @spec log_notification(state(), Notification.t()) :: state()
  defp log_notification(state, %Notification{} = notification) do
    source = if notification.source, do: "[#{notification.source}] ", else: ""
    body = if notification.body in [nil, ""], do: "", else: ": #{notification.body}"
    MingaEditor.log_message(state, "#{source}#{notification.title}#{body}")
  end
end
