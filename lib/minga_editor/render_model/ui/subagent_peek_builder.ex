defmodule MingaEditor.RenderModel.UI.SubagentPeekBuilder do
  @moduledoc "Captures task-tree facts at the Editor boundary and places the two panes at render time."

  alias Minga.RenderModel.UI.SubagentPeek
  alias MingaEditor.Agent.SubagentPeekComposer, as: Composer
  alias MingaEditor.Agent.SubagentPeekSession, as: ChildSession
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.Tasks.{Entry, Subagent}
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.State
  alias MingaEditor.RenderModel.UI.AgentChatResident
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  @doc "Captures the displayed parent's exact activation list and any focused peek."
  @spec capture(State.t()) :: {SubagentPeek.t() | nil, TranscriptProjection.t() | nil}
  def capture(
        %State{workspace: %{agent_ui: %{chat_lifecycle: {:conversation, pid}} = ui}} = state
      ) do
    windows = state.workspace.windows
    connection = state.agent_connection

    with task_id when is_binary(task_id) <- UIState.task_id(ui),
         {:ok, %Entry{subagents: [_ | _]} = entry} <- Tasks.fetch(connection.tasks, pid, task_id),
         {parent, peek} <- windows_for(windows, task_id),
         {:ok, %Window{content: {:agent_chat, :semantic}}} <- Windows.fetch(windows, parent) do
      {pane, source} =
        pane_for(peek, windows.active, entry, connection, System.os_time(:millisecond))

      model = %SubagentPeek{parent_window_id: parent, steps: steps(entry), pane: pane}
      {model, source}
    else
      _not_visible -> {nil, nil}
    end
  end

  def capture(%State{}), do: {nil, nil}

  @doc "Places parent and child using the existing window tree's pane rectangles."
  @spec build(Context.t()) :: SubagentPeek.t()
  def build(%Context{workspace: %{subagent_peek: %SubagentPeek{pane: nil} = model}}), do: model

  def build(%Context{
        workspace: %{subagent_peek: %SubagentPeek{} = model} = workspace,
        layout: layout
      }) do
    with %{content: parent_rect} <- Map.get(layout.window_layouts, model.parent_window_id),
         %{content: peek_rect} <- Map.get(layout.window_layouts, model.pane.window_id) do
      %{
        model
        | parent_rect: parent_rect,
          peek_rect: peek_rect,
          transcript: resident_transcript(workspace.peek_transcript)
      }
    else
      _unplaced -> %{model | pane: nil}
    end
  end

  def build(%Context{}), do: %SubagentPeek{}

  @spec resident_transcript(AgentChatResident.t() | nil) :: SubagentPeek.transcript()
  defp resident_transcript(%AgentChatResident{} = resident) do
    {messages, truncated?} = AgentChatResident.resident_messages(resident)
    {resident.epoch, messages, truncated?}
  end

  defp resident_transcript(nil), do: nil

  @spec windows_for(Windows.t(), String.t()) :: {Window.id(), Window.t() | nil}
  defp windows_for(windows, task_id) do
    Enum.find_value(windows.map, {windows.active, nil}, fn
      {_id, %Window{content: {:subagent_peek, {parent, {^task_id, _}}}} = peek} -> {parent, peek}
      _other -> nil
    end)
  end

  @spec pane_for(Window.t() | nil, Window.id(), Entry.t(), State.AgentConnection.t(), integer()) ::
          {SubagentPeek.pane() | nil, TranscriptProjection.t() | nil}
  defp pane_for(
         %Window{id: id, content: {:subagent_peek, {_, {_, key} = identity}}},
         active,
         entry,
         connection,
         now
       ) do
    siblings = Subagent.siblings(entry.subagents, key)

    case Enum.find_index(siblings, &(&1.invocation_key == key)) do
      nil ->
        {nil, nil}

      index ->
        selected = Enum.at(siblings, index)

        {prompt, cursor, sending?, notice} =
          Composer.presentation(connection.peek_composer, identity)

        {source, brief_open?} = child_source(connection.peek_session, identity)

        {%{
           window_id: id,
           token: Subagent.action_token(identity),
           parent: Entry.title(entry),
           title: selected.title,
           state: selected.state,
           elapsed: elapsed(selected, now),
           siblings:
             Enum.map(siblings, fn sibling ->
               token = Subagent.action_token({entry.task_id, sibling.invocation_key})
               {token, sibling.title, sibling.state}
             end),
           index: index + 1,
           brief: selected.brief,
           brief_open?: brief_open?,
           result: selected.result,
           prompt: prompt,
           cursor: cursor,
           focused?: active == id,
           editing?: active == id and connection.peek_composer.focused == {id, identity},
           sending?: sending?,
           notice: notice
         }, source}
    end
  end

  defp pane_for(nil, _active, _entry, _connection, _now), do: {nil, nil}

  @spec child_source(ChildSession.t() | nil, MingaAgent.SessionManager.foreground_identity()) ::
          {TranscriptProjection.t() | nil, boolean()}
  defp child_source(%ChildSession{identity: identity} = child, identity),
    do: {child.transcript, child.brief_open?}

  defp child_source(_reader, _identity), do: {nil, false}

  @spec steps(Entry.t()) :: [SubagentPeek.step()]
  defp steps(%Entry{task_id: task, subagents: subagents}) do
    for %Subagent{entry_id: id, invocation_key: key, title: title, reports: counts} <- subagents,
        is_integer(id) and key != nil,
        do: {id, Subagent.action_token({task, key}), "Started #{title}", report(counts)}
  end

  @spec report(Subagent.reports() | nil) :: String.t()
  defp report(nil), do: ""
  defp report({received, started}), do: "#{received} of #{started} reports in"

  @spec elapsed(Subagent.t(), integer()) :: String.t()
  defp elapsed(child, now) do
    ending = if child.state == :working, do: now, else: child.changed_at
    seconds = div(max(ending - child.started_at, 0), 1_000)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m"
  end
end
