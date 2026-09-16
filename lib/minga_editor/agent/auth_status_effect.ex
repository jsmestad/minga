defmodule MingaEditor.Agent.AuthStatusEffect do
  @moduledoc """
  Bounded live Ollama discovery for `/auth`.

  Local credential status is published before this effect is scheduled. The
  Editor effect scheduler runs the network probe off the Editor mailbox with a
  latest-wins policy and timeout. Application is correlated to the original
  session, so a late result cannot publish into a replacement session.
  """

  @behaviour MingaEditor.Effect

  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.Session
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @resource {:auth_status, :active_session}
  @timeout_ms 2_500

  @type probe :: :default | {module(), atom(), [term()]}

  @enforce_keys [:snapshot, :session, :session_id, :probe]
  defstruct [:snapshot, :session, :session_id, :probe]

  @type t :: %__MODULE__{
          snapshot: Snapshot.t(),
          session: pid() | nil,
          session_id: String.t() | nil,
          probe: probe()
        }

  @doc "Builds one latest-wins live status request."
  @spec request(Snapshot.t(), pid() | nil, String.t() | nil, keyword()) :: Request.t()
  def request(%Snapshot{} = snapshot, session, session_id, opts \\ [])
      when (is_pid(session) and (is_binary(session_id) or is_nil(session_id))) or
             (is_nil(session) and is_nil(session_id)) do
    effect = %__MODULE__{
      snapshot: snapshot,
      session: session,
      session_id: session_id,
      probe: Keyword.get(opts, :probe, :default)
    }

    Request.new(effect, @resource, Policy.latest_wins(),
      timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms)
    )
  end

  @doc "Schedules live status and settles admission failures immediately."
  @spec schedule(EditorState.t(), Snapshot.t(), pid() | nil, keyword()) :: EditorState.t()
  def schedule(%EditorState{} = state, %Snapshot{} = snapshot, session, opts \\ []) do
    request = request(snapshot, session, capture_session_id(session), opts)

    case state.effect_scheduler do
      nil -> apply_failure(state, request.effect, :scheduler_unavailable)
      scheduler -> schedule_on(state, scheduler, request)
    end
  end

  @impl true
  @spec run(t()) :: {:ok, Credentials.ollama_availability()} | {:error, term()}
  def run(%__MODULE__{snapshot: snapshot, probe: :default}) do
    {:ok, Credentials.ollama_availability(snapshot)}
  end

  def run(%__MODULE__{snapshot: snapshot, probe: {module, function, args}})
      when is_atom(module) and is_atom(function) and is_list(args) do
    {:ok, apply(module, function, [snapshot | args])}
  rescue
    error -> {:error, {:probe_exception, error.__struct__}}
  catch
    :exit, reason -> {:error, {:probe_exit, reason}}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        %EditorState{} = state,
        %Outcome{request: %{effect: %__MODULE__{} = effect}, value: {:completed, availability}} =
          outcome
      ) do
    if current_session?(state, effect.session, effect.session_id) do
      {publish(state, effect.session, availability), outcome}
    else
      {state, Outcome.stale(outcome, :agent_session_changed)}
    end
  end

  def apply(
        %EditorState{} = state,
        %Outcome{request: %{effect: %__MODULE__{} = effect}, value: {:failed, reason}} = outcome
      ) do
    if current_session?(state, effect.session, effect.session_id) do
      {publish(state, effect.session, {:unavailable, reason}), outcome}
    else
      {state, Outcome.stale(outcome, :agent_session_changed)}
    end
  end

  def apply(%EditorState{} = state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _payload}}) when status in [:completed, :failed], do: true
  def render?(%Outcome{}), do: false

  @spec schedule_on(EditorState.t(), GenServer.server(), Request.t()) :: EditorState.t()
  defp schedule_on(state, scheduler, request) do
    case EffectScheduler.schedule(scheduler, request) do
      {:ok, _request_id, _disposition} -> state
      {:error, reason} -> apply_failure(state, request.effect, reason)
    end
  catch
    :exit, reason -> apply_failure(state, request.effect, {:scheduler_unavailable, reason})
  end

  @spec apply_failure(EditorState.t(), t(), term()) :: EditorState.t()
  defp apply_failure(state, effect, reason) do
    if current_session?(state, effect.session, effect.session_id) do
      publish(state, effect.session, {:unavailable, reason})
    else
      state
    end
  end

  @spec current_session?(EditorState.t(), pid() | nil, String.t() | nil) :: boolean()
  defp current_session?(state, nil, nil), do: is_nil(Runtime.active_session(state.shell_runtime))

  defp current_session?(state, session, session_id) when is_pid(session) do
    Runtime.active_session(state.shell_runtime) == session and session_alive?(session) and
      capture_session_id(session) == session_id
  end

  defp current_session?(_state, _session, _session_id), do: false

  @spec capture_session_id(pid() | nil) :: String.t() | nil
  defp capture_session_id(nil), do: nil

  defp capture_session_id(session) when is_pid(session) do
    Session.session_id(session)
  catch
    :exit, _reason -> nil
  end

  @spec session_alive?(pid()) :: boolean()
  defp session_alive?(session) when node(session) != node(), do: true
  defp session_alive?(session), do: Process.alive?(session)

  @spec publish(EditorState.t(), pid() | nil, Credentials.ollama_availability()) ::
          EditorState.t()
  defp publish(state, session, availability) when is_pid(session) do
    Session.add_system_message(session, availability_message(availability))
    NoticeWorkflow.publish(state, availability_notice(availability))
  catch
    :exit, _reason -> state
  end

  defp publish(state, nil, availability) do
    NoticeWorkflow.publish(state, availability_notice(availability))
  end

  @spec availability_message(Credentials.ollama_availability()) :: String.t()
  defp availability_message(:available), do: "Ollama availability: ✓ available (local)"
  defp availability_message({:unavailable, _reason}), do: "Ollama availability: ✗ unavailable"
  defp availability_message(:pending), do: "Ollama availability: … checking"

  @spec availability_notice(Credentials.ollama_availability()) :: String.t()
  defp availability_notice(:available), do: "Ollama available"
  defp availability_notice({:unavailable, _reason}), do: "Ollama unavailable"
  defp availability_notice(:pending), do: "Checking Ollama availability"
end
