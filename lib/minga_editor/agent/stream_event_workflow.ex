defmodule MingaEditor.Agent.StreamEventWorkflow do
  @moduledoc """
  Applies transcript and coalesced stream events in mailbox order.

  A batch folds preview updates in arrival order, requests one render, and synchronizes the transcript at most once.
  """

  alias MingaEditor.Agent.ToolEventWorkflow
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState

  @doc "Applies one durable stream delta through the bounded batch workflow."
  @spec delta(EditorState.t(), term()) :: EditorState.t()
  def delta(%EditorState{} = state, event), do: batch(state, [event])

  @doc "Applies a messages-changed event and refreshes transcript-derived presentation."
  @spec messages_changed(EditorState.t()) :: EditorState.t()
  def messages_changed(%EditorState{} = state) do
    state =
      TraditionalWorkflow.install_agent_panel(
        state,
        Panel.bump_message_version(state.workspace.agent_ui.panel)
      )

    state
    |> MingaEditor.schedule_render(16)
    |> AgentLifecycle.sync_transcript(:messages_changed)
  end

  @doc "Applies one coalesced stream batch with one render and at most one transcript sync."
  @spec batch(EditorState.t(), [term()]) :: EditorState.t()
  def batch(%EditorState{} = state, []), do: state

  def batch(%EditorState{} = state, events) when is_list(events) do
    state = Enum.reduce(events, state, &replay_delta/2)
    sync_transcript? = transcript_affecting_batch?(events)

    state = maybe_bump_message_version(state, sync_transcript?)
    state = MingaEditor.schedule_render(state, 16)
    sync_transcript(state, sync_transcript?)
  end

  @spec maybe_bump_message_version(EditorState.t(), boolean()) :: EditorState.t()
  defp maybe_bump_message_version(state, true) do
    TraditionalWorkflow.install_agent_panel(
      state,
      Panel.bump_message_version(state.workspace.agent_ui.panel)
    )
  end

  defp maybe_bump_message_version(state, false), do: state

  @spec replay_delta(term(), EditorState.t()) :: EditorState.t()
  defp replay_delta({:tool_update, _tool_call_id, _name, _partial} = event, state),
    do: ToolEventWorkflow.replay(state, event)

  defp replay_delta(_event, state), do: state

  @spec transcript_affecting_batch?([term()]) :: boolean()
  defp transcript_affecting_batch?(events) do
    Enum.any?(events, fn
      {:text_delta, _delta} -> true
      {:thinking_delta, _delta} -> true
      _event -> false
    end)
  end

  @spec sync_transcript(EditorState.t(), boolean()) :: EditorState.t()
  defp sync_transcript(state, true), do: AgentLifecycle.sync_transcript(state)
  defp sync_transcript(state, false), do: state
end
