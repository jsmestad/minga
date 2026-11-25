defmodule MingaEditor.Agent.TurnRequest do
  @moduledoc """
  A composer send or a stop the Editor asked an Agent session for and has not seen answered.

  A Session admits a send only after its provider has prepared the request, which can take seconds, and it handles a stop only between its other work. The Editor therefore never calls the Session for either (#4296). It sends one `:gen_server.send_request/2` and keeps this record until the reply arrives. The request monitors the Session, so a Session that exits answers with its exit. A Session on another node is asked by a worker under the effect scheduler, which the record monitors in the same way.

  A send belongs to the composer it was pressed in. While it is out, that composer counts the pressed text as taken (`MingaEditor.Agent.DraftWorkflow.begin_send/3`), so a second press never sends the same text again. The answer is applied to that composer whether or not its workspace is still in front; `MingaEditor.Commands.Agent.settle_turn_request/3` says what each answer means. A send that never got an answer keeps its text.
  """

  alias MingaAgent.Session
  alias MingaAgent.Session.TurnExecution
  alias MingaEditor.Agent.DraftWorkflow
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @typedoc "A send with the content the Session gets and the raw composer text it took, or a stop of one turn."
  @type work ::
          {:send, Session.composer_send(), TurnExecution.content(), raw :: String.t()}
          | {:stop, {String.t(), String.t()}}

  @typedoc "How the answer comes back: a local Session's reply, or a worker asking a Session on another node. `:unsent` until the request has started."
  @type transport ::
          {:request, :gen_server.request_id()} | {:worker, pid(), reference()} | :unsent

  @typedoc "What the Session answered, or `:session_down` when it exited or could not be asked."
  @type answer :: term() | :session_down

  @type t :: %__MODULE__{
          token: reference(),
          transport: transport(),
          workspace: non_neg_integer() | nil,
          session: pid(),
          work: work()
        }

  @enforce_keys [:token, :transport, :workspace, :session, :work]
  defstruct @enforce_keys

  @doc """
  Sends `content` from the composer in front to `session` and returns at once. `raw` is the composer text the press took, or `:all` for a press that takes everything the composer holds.

  The composer keeps its text until the Session answers. A composer that already has a send out is refused with one line, and its text stays.
  """
  @spec deliver(
          EditorState.t(),
          pid(),
          Session.composer_send(),
          TurnExecution.content(),
          String.t() | :all
        ) :: EditorState.t()
  def deliver(%EditorState{} = state, session, send, content, raw) when is_pid(session) do
    owner = DraftWorkflow.front_owner(state)

    if is_integer(owner) and not sending_from?(state, owner),
      do: begin_send(state, owner, session, {send, content}, raw),
      else: refuse_second_send(state)
  end

  @spec begin_send(
          EditorState.t(),
          non_neg_integer(),
          pid(),
          {Session.composer_send(), TurnExecution.content()},
          String.t() | :all
        ) :: EditorState.t()
  defp begin_send(state, owner, session, {send, content}, pressed) do
    token = make_ref()

    case DraftWorkflow.begin_send(state, token, pressed) do
      {:ok, raw, marked} ->
        ask(marked, %__MODULE__{
          token: token,
          transport: :unsent,
          workspace: owner,
          session: session,
          work: {:send, send, content, raw}
        })

      :pending ->
        refuse_second_send(state)
    end
  end

  @spec refuse_second_send(EditorState.t()) :: EditorState.t()
  defp refuse_second_send(state),
    do:
      NoticeWorkflow.publish(
        state,
        "Wait for the earlier message to be sent. The draft was kept."
      )

  @doc "Asks `session` to stop the turn `target` and returns at once."
  @spec stop(EditorState.t(), pid(), {String.t(), String.t()}) :: EditorState.t()
  def stop(%EditorState{} = state, session, {_, _} = target) when is_pid(session) do
    ask(state, %__MODULE__{
      token: make_ref(),
      transport: :unsent,
      workspace: DraftWorkflow.front_owner(state),
      session: session,
      work: {:stop, target}
    })
  end

  # A request that could not be started is settled at once, as a Session that never answered.
  @spec ask(EditorState.t(), t()) :: EditorState.t()
  defp ask(state, %__MODULE__{token: token, session: session, work: work} = request) do
    case start(state, token, session, work) do
      {:ok, transport} ->
        EditorState.track_agent_turn_request(state, %{request | transport: transport})

      :error ->
        AgentCommands.settle_turn_request(state, request, :session_down)
    end
  end

  @doc "Handles a request's reply, its worker's result or its monitor; anything else is unrelated."
  @spec response(EditorState.t(), term()) :: {:handled, EditorState.t()} | :unrelated
  def response(%EditorState{agent_connection: %{turn_requests: requests}} = state, message) do
    Enum.find_value(requests, :unrelated, fn {_token, request} ->
      case answer(request, message) do
        :no_reply -> nil
        {:answer, answer} -> {:handled, settle(state, request, answer)}
      end
    end)
  end

  @spec settle(EditorState.t(), t(), answer()) :: EditorState.t()
  defp settle(state, %__MODULE__{token: token} = request, answer) do
    state
    |> EditorState.finish_agent_turn_request(token)
    |> AgentCommands.settle_turn_request(request, answer)
  end

  @spec answer(t(), term()) :: {:answer, answer()} | :no_reply
  defp answer(%__MODULE__{transport: {:request, request}}, message) do
    case :gen_server.check_response(message, request) do
      :no_reply -> :no_reply
      {:reply, reply} -> {:answer, reply}
      {:error, {_reason, _server}} -> {:answer, :session_down}
    end
  end

  defp answer(
         %__MODULE__{token: token, transport: {:worker, _worker, monitor}},
         {:turn_request_result, token, reply}
       ) do
    Process.demonitor(monitor, [:flush])
    {:answer, reply}
  end

  defp answer(
         %__MODULE__{transport: {:worker, worker, monitor}},
         {:DOWN, monitor, :process, worker, _reason}
       ),
       do: {:answer, :session_down}

  defp answer(%__MODULE__{}, _message), do: :no_reply

  @spec sending_from?(EditorState.t(), non_neg_integer()) :: boolean()
  defp sending_from?(%EditorState{agent_connection: %{turn_requests: requests}}, owner) do
    Enum.any?(requests, fn {_token, request} ->
      request.workspace == owner and match?({:send, _, _, _}, request.work)
    end)
  end

  @spec start(EditorState.t(), reference(), pid(), work()) :: {:ok, transport()} | :error
  defp start(_state, _token, session, {:send, send, content, _raw})
       when node(session) == node(),
       do: {:ok, {:request, Session.request_composer_send(session, send, content)}}

  defp start(_state, _token, session, {:stop, target}) when node(session) == node(),
    do: {:ok, {:request, Session.request_stop_turn(session, target)}}

  defp start(%EditorState{effect_scheduler: nil}, _token, _session, _work), do: :error

  defp start(%EditorState{effect_scheduler: scheduler}, token, session, work) do
    editor = self()

    case Task.Supervisor.start_child(EffectScheduler.task_supervisor(scheduler), fn ->
           send(editor, {:turn_request_result, token, ask_remote(session, work, editor)})
         end) do
      {:ok, worker} -> {:ok, {:worker, worker, Process.monitor(worker)}}
      _not_started -> :error
    end
  catch
    :exit, _reason -> :error
  end

  # A Session on another node has no saved composer for this Editor, so only these three reach it.
  @spec ask_remote(pid(), work(), pid()) :: answer()
  defp ask_remote(session, {:send, :prompt, content, _raw}, editor),
    do: SessionClient.send_prompt(session, content, editor)

  defp ask_remote(session, {:send, :follow_up, content, _raw}, _editor) do
    Session.queue_follow_up(session, content)
  catch
    :exit, _reason -> :session_down
  end

  defp ask_remote(session, {:stop, target}, _editor) do
    Session.stop_turn(session, target)
  catch
    :exit, _reason -> :session_down
  end
end
