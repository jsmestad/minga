defmodule MingaEditor.Agent.QuestionResponse do
  @moduledoc "Submits a response to the displayed Session without blocking the editor."

  alias MingaAgent.{Question, Session}
  alias MingaEditor.Agent.PendingQuestion
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace

  @type authority :: pid() | {pid(), binary()}

  @doc "Installs a receipt only for an exact remote Session already attached to this editor."
  @spec bind_remote_attachment(State.t(), pid(), binary()) :: State.t()
  def bind_remote_attachment(
        %State{shell_runtime: %{state: %{tab_bar: %TabBar{} = tabs}}} = state,
        session,
        receipt
      ) do
    case TabBar.find_workspace_by_session(tabs, session) do
      %Workspace{} ->
        State.remember_remote_question_receipt(state, session, receipt)

      nil ->
        state
    end
  end

  def bind_remote_attachment(%State{} = state, _session, _receipt), do: state

  @doc "Drops the private local receipt for the disconnected Session."
  @spec retire_remote_attachment(State.t(), pid()) :: State.t()
  def retire_remote_attachment(%State{} = state, session) when node(session) != node(),
    do: State.retire_remote_question_receipt(state, session)

  def retire_remote_attachment(%State{} = state, _session), do: state

  @doc "Returns the active remote driver's receipt, or the PID for a non-capable attachment."
  @spec remote_authority(State.t(), pid(), pid()) :: authority()
  def remote_authority(%State{agent_connection: connection}, session, editor) do
    case Map.get(connection.question_receipts, session) do
      receipt when is_binary(receipt) -> {editor, receipt}
      nil -> editor
    end
  end

  @doc "Schedules a response against the exact question and current driver attachment."
  @spec submit(State.t(), PendingQuestion.t(), Question.response()) :: State.t()
  def submit(%State{effect_scheduler: nil} = state, pending, _response),
    do: failed(state, pending.offer, :scheduler_unavailable)

  def submit(%State{effect_scheduler: scheduler} = state, pending, response) do
    editor = self()
    driver = driver(state, pending.session, editor)
    supervisor = EffectScheduler.task_supervisor(scheduler)

    case Task.Supervisor.start_child(supervisor, fn ->
           send_response(editor, pending, response, driver)
         end) do
      {:ok, _worker} -> state
      {:error, _reason} -> failed(state, pending.offer, :scheduler_unavailable)
    end
  catch
    :exit, _reason -> failed(state, pending.offer, :scheduler_unavailable)
  end

  @doc "Reports submission failure only in the workspace that still shows the question."
  @spec failed(State.t(), pos_integer(), term()) :: State.t()
  def failed(state, offer, reason) do
    case TraditionalState.agent(state.shell_runtime.state).pending_question do
      %PendingQuestion{offer: ^offer} -> NoticeWorkflow.publish(state, message(reason))
      _changed -> state
    end
  end

  @spec driver(State.t(), pid(), pid()) :: authority()
  defp driver(%State{agent_connection: %{agent_ingest: ingest}}, session, _editor)
       when node(session) == node() and is_pid(ingest),
       do: ingest

  defp driver(state, session, editor) when node(session) != node(),
    do: remote_authority(state, session, editor)

  defp driver(_state, _session, editor), do: editor

  @spec send_response(pid(), PendingQuestion.t(), Question.response(), authority()) :: :ok
  defp send_response(editor, pending, response, driver) do
    case respond(pending, response, driver) do
      :ok ->
        :ok

      {:error, reason} ->
        send(editor, {:agent_question_response_failed, pending.offer, reason})
        :ok
    end
  end

  @spec respond(PendingQuestion.t(), Question.response(), authority()) :: :ok | {:error, term()}
  defp respond(%PendingQuestion{session: session, target: target}, response, driver)
       when node(session) == node() and is_pid(driver) do
    Session.respond_to_question_as(session, driver, target, response)
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp respond(%PendingQuestion{}, _response, driver) when is_pid(driver),
    do: {:error, :not_driver}

  defp respond(%PendingQuestion{session: session, target: target}, response, {driver, receipt}),
    do: SessionClient.respond_to_question(session, target, response, {driver, receipt})

  @spec message(term()) :: String.t()
  defp message(:invalid_answer), do: "Enter an answer or choose Cancel question."
  defp message(:not_driver), do: "Only the session driver can answer this question."
  defp message(:question_not_found), do: "That Agent question is no longer available."
  defp message(_reason), do: "Could not answer the Agent question. Reopen it to try again."
end
