defmodule MingaEditor.Agent.StreamEventWorkflow do
  @moduledoc """
  Applies transcript and coalesced stream events in mailbox order.

  A batch folds preview updates in arrival order, requests one render, and synchronizes the transcript at most once.
  """

  alias MingaEditor.Agent.ToolEventWorkflow
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.WorkspaceWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaAgent.Session

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

    state = maybe_rename_workspace_from_assistant(state)
    state = MingaEditor.schedule_render(state, 16)
    state = AgentLifecycle.sync_transcript(state)
    AgentLifecycle.maybe_update_tab_label(state)
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

  @spec maybe_rename_workspace_from_assistant(EditorState.t()) :: EditorState.t()
  defp maybe_rename_workspace_from_assistant(state) do
    with pid when is_pid(pid) <- Runtime.active_session(state.shell_runtime),
         %TabBar{} = tab_bar <- traditional_tab_bar(state),
         %Workspace{custom_name: nil} = workspace <-
           TabBar.find_workspace_by_session(tab_bar, pid),
         text when is_binary(text) <- first_assistant_opening(safe_messages(pid)),
         candidate = text |> String.slice(0, 30) |> String.trim(),
         true <- candidate != "" and candidate != workspace.label do
      WorkspaceWorkflow.install_auto_named_workspace(state, workspace.id, text)
    else
      _unavailable -> state
    end
  rescue
    _error -> state
  end

  @spec first_assistant_opening([term()]) :: String.t() | nil
  defp first_assistant_opening(messages) do
    Enum.find_value(messages, fn
      {:assistant, text} when is_binary(text) and text != "" ->
        text |> String.split("\n") |> hd() |> String.trim()

      _message ->
        nil
    end)
  end

  @spec safe_messages(pid()) :: [term()]
  defp safe_messages(pid) do
    Session.messages(pid)
  catch
    :exit, _reason -> []
  end

  @spec traditional_tab_bar(EditorState.t()) :: TabBar.t() | nil
  defp traditional_tab_bar(%EditorState{
         shell_runtime: %Runtime{state: %TraditionalState{} = state}
       }),
       do: TraditionalState.tab_bar(state)

  defp traditional_tab_bar(%EditorState{}), do: nil
end
