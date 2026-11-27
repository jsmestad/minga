defmodule MingaEditor.Agent.SubagentPeekSession do
  @moduledoc "Tracks the visible peek's child independently of the parent Agent transcript."

  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaEditor.Agent.Ingest
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.State

  @typep link ::
           {:connecting, reference(), SessionManager.foreground_subagent() | nil}
           | {:live, SessionManager.foreground_subagent()}
           | {:unavailable, term()}
  @type t :: %__MODULE__{
          identity: SessionManager.foreground_identity(),
          link: link(),
          read: {:gen_server.request_id(), boolean()} | nil,
          transcript: TranscriptProjection.t(),
          prefix: Minga.Keymap.Bindings.node_t() | nil,
          brief_open?: boolean()
        }

  @enforce_keys [:identity, :link, :transcript]
  defstruct [:identity, :link, :transcript, :read, :prefix, brief_open?: false]

  @doc "Resolves and attaches the child without taking a Session or Ingest call on the Editor mailbox."
  @spec select(State.t(), SessionManager.foreground_identity()) :: State.t()
  def select(
        %State{agent_connection: %{peek_session: %__MODULE__{identity: identity}}} = state,
        identity
      ),
      do: state

  def select(%State{agent_connection: %{agent_ingest: ingest}} = state, identity)
      when is_pid(ingest) do
    attach(close(state), identity, ingest)
  end

  def select(%State{} = state, identity) do
    State.install_subagent_peek_session(state, %__MODULE__{
      identity: identity,
      link: {:unavailable, :editor_ingest_unavailable},
      transcript: TranscriptProjection.new()
    })
  end

  @doc "Returns the peek-only pending key sequence."
  @spec prefix(State.t()) :: Minga.Keymap.Bindings.node_t() | nil
  def prefix(%State{agent_connection: %{peek_session: %__MODULE__{prefix: prefix}}}), do: prefix
  def prefix(%State{}), do: nil

  @doc "Remembers or clears a pending peek-only key sequence."
  @spec remember_prefix(State.t(), Minga.Keymap.Bindings.node_t() | nil) :: State.t()
  def remember_prefix(
        %State{agent_connection: %{peek_session: %__MODULE__{prefix: prefix}}} = state,
        prefix
      ),
      do: state

  def remember_prefix(
        %State{agent_connection: %{peek_session: %__MODULE__{} = peek}} = state,
        prefix
      ),
      do: State.install_subagent_peek_session(state, %{peek | prefix: prefix})

  def remember_prefix(%State{} = state, _prefix), do: state

  @doc "Toggles the Brief in the selected child without changing its transcript."
  @spec toggle_brief(State.t()) :: State.t()
  def toggle_brief(%State{agent_connection: %{peek_session: %__MODULE__{} = peek}} = state),
    do: State.install_subagent_peek_session(state, %{peek | brief_open?: not peek.brief_open?})

  def toggle_brief(%State{} = state), do: state

  @doc "Releases the visible reader, not the retained child Session."
  @spec close(State.t()) :: State.t()
  def close(%State{agent_connection: %{peek_session: %__MODULE__{read: {request, _}}}} = state) do
    _ = :gen_server.receive_response(request, 0)
    State.install_subagent_peek_session(state, nil)
  end

  def close(%State{agent_connection: %{peek_session: %__MODULE__{}}} = state),
    do: State.install_subagent_peek_session(state, nil)

  def close(%State{} = state), do: state

  @doc "Installs the worker's result only for the same selected child and attachment."
  @spec ready(
          State.t(),
          reference(),
          {:ok, SessionManager.foreground_subagent()} | {:error, term()}
        ) ::
          State.t()
  def ready(%State{agent_connection: connection} = state, token, result) do
    case connection.peek_session do
      %__MODULE__{link: {:connecting, ^token, candidate}} = peek ->
        finish_attach(state, peek, candidate, result)

      _stale ->
        state
    end
  end

  @doc "Applies managed availability only to the same invocation and physical child."
  @spec child_changed(State.t(), SessionManager.foreground_subagent()) :: State.t()
  def child_changed(%State{agent_connection: connection} = state, %{identity: identity} = child) do
    case connection.peek_session do
      %__MODULE__{identity: ^identity, link: {:live, %{session_id: id}}} = peek
      when id == child.session_id ->
        State.install_subagent_peek_session(state, %{peek | link: {:live, child}})

      %__MODULE__{identity: ^identity, link: {:connecting, token, _}} = peek ->
        State.install_subagent_peek_session(state, %{peek | link: {:connecting, token, child}})

      %__MODULE__{identity: ^identity, link: {:unavailable, :subagent_unavailable}} ->
        attach(state, identity, connection.agent_ingest)

      _other ->
        state
    end
  end

  @doc "Retires a disposed child without installing any later reads from it."
  @spec child_disposed(State.t(), SessionManager.foreground_disposal()) :: State.t()
  def child_disposed(
        %State{agent_connection: connection} = state,
        %{identity: identity, session_id: id}
      ) do
    case connection.peek_session do
      %__MODULE__{identity: ^identity, link: {:live, %{session_id: ^id}}} = peek ->
        retire(state, peek)

      %__MODULE__{identity: ^identity, link: {:connecting, _, nil}} = peek ->
        retire(state, peek)

      %__MODULE__{identity: ^identity, link: {:connecting, _, %{session_id: ^id}}} = peek ->
        retire(state, peek)

      _other ->
        state
    end
  end

  @doc "Coalesces the visible child's stream updates behind one cursor read."
  @spec refresh(State.t(), pid()) :: State.t()
  def refresh(
        %State{
          agent_connection: %{
            peek_session: %__MODULE__{link: {:live, %{pid: pid}}, read: {request, _}} = peek
          }
        } = state,
        pid
      ),
      do: State.install_subagent_peek_session(state, %{peek | read: {request, true}})

  def refresh(
        %State{
          agent_connection: %{
            peek_session: %__MODULE__{link: {:live, %{pid: pid}}, read: nil} = peek
          }
        } = state,
        pid
      ) do
    cursor = peek.transcript.source_cursor || :snapshot
    request = Session.request_editor_transcript(pid, cursor)
    State.install_subagent_peek_session(state, %{peek | read: {request, false}})
  end

  def refresh(%State{} = state, _pid), do: state

  @doc "Installs the correlated reply from the selected Session, without updating the parent's display."
  @spec response(State.t(), term()) :: {:handled, State.t()} | :unrelated
  def response(
        %State{
          agent_connection: %{
            peek_session: %__MODULE__{link: {:live, %{pid: pid}}, read: {request, dirty?}} = peek
          }
        } = state,
        message
      ) do
    case :gen_server.check_response(message, request) do
      :no_reply ->
        :unrelated

      {:reply, reply} ->
        transcript = apply_read(peek.transcript, reply, state.appearance.theme.syntax)

        state =
          State.install_subagent_peek_session(state, %{peek | transcript: transcript, read: nil})

        {:handled, if(dirty?, do: refresh(state, pid), else: state)}

      {:error, {_reason, _server}} ->
        {:handled,
         State.install_subagent_peek_session(state, %{
           peek
           | read: nil,
             link: {:unavailable, :subagent_stopped}
         })}
    end
  end

  def response(%State{}, _message), do: :unrelated

  @spec attach(State.t(), SessionManager.foreground_identity(), pid()) :: State.t()
  defp attach(state, identity, ingest) do
    token = make_ref()
    manager = state.agent_connection.session_manager
    editor = self()

    work = fn ->
      send(editor, {:subagent_peek_ready, token, find_and_attach(manager, identity, ingest)})
    end

    link =
      case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, work) do
        {:ok, _pid} -> {:connecting, token, nil}
        {:error, reason} -> {:unavailable, reason}
      end

    State.install_subagent_peek_session(state, %__MODULE__{
      identity: identity,
      link: link,
      transcript: TranscriptProjection.new()
    })
  end

  @spec find_and_attach(GenServer.server(), SessionManager.foreground_identity(), pid()) ::
          {:ok, SessionManager.foreground_subagent()} | {:error, term()}
  defp find_and_attach(manager, identity, ingest) do
    with {:ok, child} <- SessionManager.foreground_subagent(manager, identity),
         :ok <- Ingest.subscribe_peek(ingest, child.pid) do
      {:ok, child}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec finish_attach(
          State.t(),
          t(),
          SessionManager.foreground_subagent() | nil,
          {:ok, SessionManager.foreground_subagent()} | {:error, term()}
        ) :: State.t()
  defp finish_attach(
         state,
         peek,
         %{session_id: id, writable?: true} = latest,
         {:ok, %{session_id: id}}
       ),
       do: finish_attach(state, peek, nil, {:ok, latest})

  defp finish_attach(state, peek, _candidate, {:ok, child}) do
    state
    |> State.install_subagent_peek_session(%{peek | link: {:live, child}})
    |> refresh(child.pid)
  end

  defp finish_attach(state, peek, %{}, {:error, :subagent_unavailable}),
    do: attach(state, peek.identity, state.agent_connection.agent_ingest)

  defp finish_attach(state, peek, _candidate, {:error, reason}),
    do: State.install_subagent_peek_session(state, %{peek | link: {:unavailable, reason}})

  @spec retire(State.t(), t()) :: State.t()
  defp retire(state, peek) do
    state
    |> close()
    |> State.install_subagent_peek_session(%{
      peek
      | read: nil,
        link: {:unavailable, :subagent_stopped}
    })
  end

  @spec apply_read(TranscriptProjection.t(), Session.editor_arrival_transcript(), map()) ::
          TranscriptProjection.t()
  defp apply_read(projection, {:unchanged, cursor}, _syntax),
    do: TranscriptProjection.advance_source_cursor(projection, cursor)

  defp apply_read(projection, {:replace, _outcome, snapshot, _files}, syntax) do
    TranscriptProjection.replace(
      projection,
      snapshot.entries,
      snapshot.pinned_ids,
      snapshot.cursor,
      {nil, syntax, &MingaEditor.AgentLifecycle.style_message/3}
    )
  end

  defp apply_read(projection, {:changes, changes}, syntax) do
    {next, _reading} =
      TranscriptProjection.apply_changes(
        projection,
        changes,
        :follow,
        {nil, syntax, &MingaEditor.AgentLifecycle.style_message/3}
      )

    next
  end
end
