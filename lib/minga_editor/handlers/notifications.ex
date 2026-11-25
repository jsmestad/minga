defmodule MingaEditor.Handlers.Notifications do
  @moduledoc """
  Notification helpers: building, displaying, and auto-dismissing editor notifications.

  Changes when: notification presentation, scheduling, or lifecycle logic changes.
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Notification

  @conversation_read_only_id "agent:conversation_read_only"

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

  @doc """
  Shows a model's plan limit with a "Choose another model" action that opens `/model`.

  The chat transcript already carries the same sentence; this adds the action. Opening the picker keeps the draft.
  """
  @spec model_limit_reached(state(), String.t()) :: state()
  def model_limit_reached(state, message) when is_binary(message) do
    put_notification(
      state,
      Notification.new(
        id: "agent:model_limit",
        level: :warning,
        title: "Plan limit reached",
        body: message,
        source: "Agent",
        actions: [
          %{
            id: "choose_model",
            label: "Choose another model",
            dispatch: {:command, :agent_pick_model}
          }
        ]
      )
    )
  end

  @doc """
  Offers a new conversation when a restored one can only be read.

  A conversation continues only in the folder it worked in. The transcript already carries `line`, which says why this one cannot; this adds the next step as an action, and names its key when one is bound.
  """
  @spec conversation_read_only(state(), String.t()) :: state()
  def conversation_read_only(state, line) when is_binary(line) do
    put_notification(
      state,
      Notification.new(
        id: @conversation_read_only_id,
        level: :warning,
        title: "This conversation can only be read",
        body: read_only_body(line, new_session_key(state)),
        source: "Agent",
        actions: [
          %{
            id: "new_conversation",
            label: "New conversation",
            dispatch: {:command, :agent_new_session}
          }
        ]
      )
    )
  end

  @doc "Removes the read-only card once the conversation on screen is one that continues, or a new one."
  @spec dismiss_conversation_read_only(state()) :: state()
  def dismiss_conversation_read_only(state) do
    %{
      state
      | feedback:
          MingaEditor.State.Feedback.dismiss_notification(
            state.feedback,
            @conversation_read_only_id
          )
    }
  end

  @spec read_only_body(String.t(), String.t() | nil) :: String.t()
  defp read_only_body(line, nil), do: line
  # The line ends with the folder's path, which a narrow surface may cut. The key comes first.
  defp read_only_body(line, key), do: "Key: #{key} starts a new conversation. #{line}"

  @spec new_session_key(state()) :: String.t() | nil
  defp new_session_key(state) do
    Minga.Keymap.Scope.Agent.new_session_key_hint(
      Minga.Keymap.leader_trie(),
      state.interaction.editing_model,
      Minga.Config.get(:space_leader)
    )
  end

  @doc """
  Tells the user that a workspace holds approved agent edits that are not on disk.

  The Publish and Discard actions carry the workspace id, so a click acts on this workspace even when another one is active. The card stays until the edits are published or discarded.
  """
  @spec agent_edits_unpublished(state(), pos_integer(), String.t(), pos_integer()) :: state()
  def agent_edits_unpublished(state, workspace_id, workspace_label, file_count)
      when is_integer(workspace_id) and is_binary(workspace_label) and is_integer(file_count) and
             file_count > 0 do
    put_notification(
      state,
      Notification.new(
        id: agent_edits_notification_id(workspace_id),
        level: :warning,
        title: agent_edits_title(file_count),
        body:
          "#{workspace_label}: approved edits are staged. Publish writes them to disk and open buffers; Discard drops them. Key: SPC a p publishes or discards.",
        source: "Agent",
        actions: [
          %{
            id: "publish",
            label: "Publish",
            dispatch: {:command, {:agent_edits_publish, workspace_id}}
          },
          %{
            id: "discard",
            label: "Discard",
            dispatch: {:command, {:agent_edits_discard, workspace_id}}
          }
        ]
      )
    )
  end

  @doc "Removes a workspace's unpublished-agent-edits card after its edits are published or discarded."
  @spec dismiss_agent_edits(state(), pos_integer()) :: state()
  def dismiss_agent_edits(state, workspace_id) when is_integer(workspace_id) do
    %{
      state
      | feedback:
          MingaEditor.State.Feedback.dismiss_notification(
            state.feedback,
            agent_edits_notification_id(workspace_id)
          )
    }
  end

  @doc "Returns the user-visible title for unpublished agent edits."
  @spec agent_edits_title(pos_integer()) :: String.t()
  def agent_edits_title(1), do: "1 agent-edited file is not on disk"
  def agent_edits_title(count), do: "#{count} agent-edited files are not on disk"

  @spec agent_edits_notification_id(pos_integer()) :: String.t()
  defp agent_edits_notification_id(workspace_id), do: "agent:unpublished_edits:#{workspace_id}"

  # ── Private helpers ──────────────────────────────────────────────────

  @spec put_notification(state(), Notification.t()) :: state()
  defp put_notification(state, %Notification{} = notification) do
    notification = maybe_schedule_notification_dismiss(notification, state.frontend.backend)

    state = log_notification(state, notification)

    %{
      state
      | feedback: MingaEditor.State.Feedback.upsert_notification(state.feedback, notification)
    }
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
    Minga.Log.info(:editor, "#{source}#{notification.title}#{body}")
    state
  end
end
