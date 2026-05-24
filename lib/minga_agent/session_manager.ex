defmodule MingaAgent.SessionManager do
  @moduledoc """
  Owns agent session lifecycle independently of any UI.

  Maps human-readable session IDs (e.g., `"session-1"`) to session PIDs.
  Sessions are started via `MingaAgent.Supervisor` (DynamicSupervisor) and
  monitored here. When a session dies, the manager broadcasts an
  `:agent_session_stopped` event so the Editor (or any subscriber) can
  react without monitoring PIDs directly.
  """

  use GenServer

  alias MingaAgent.Session
  alias MingaAgent.SessionMetadata
  alias MingaAgent.Subagent.Handle

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Internal state of the SessionManager."
  @type state :: %{
          sessions: %{String.t() => session_entry()},
          background_subagents: %{String.t() => Handle.t()},
          next_id: pos_integer()
        }

  @typedoc "An entry in the sessions map."
  @type session_entry :: %{
          pid: pid(),
          monitor_ref: reference()
        }

  # ── Event payload ──────────────────────────────────────────────────────────

  defmodule SessionStoppedEvent do
    @moduledoc "Payload for `:agent_session_stopped` events."
    @enforce_keys [:session_id, :pid, :reason]
    defstruct [:session_id, :pid, :reason]

    @type t :: %__MODULE__{
            session_id: String.t(),
            pid: pid(),
            reason: term()
          }
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc "Starts the SessionManager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a new agent session with a generated human-readable ID.

  Returns `{:ok, session_id, pid}` on success.
  """
  @spec start_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_session(opts \\ []) do
    start_session(__MODULE__, opts)
  end

  @doc "Starts a new agent session through the given manager."
  @spec start_session(GenServer.server(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start_session(manager, opts) do
    GenServer.call(manager, {:start_session, opts})
  end

  @doc "Starts a background sub-agent, sends it the task asynchronously, and returns a stable handle."
  @spec start_background_subagent(pid() | nil, String.t(), keyword()) ::
          {:ok, Handle.t()} | {:error, term()}
  def start_background_subagent(parent_session_pid, task, opts \\ []) when is_binary(task) do
    start_background_subagent(__MODULE__, parent_session_pid, task, opts)
  end

  @doc "Starts a background sub-agent through the given manager."
  @spec start_background_subagent(GenServer.server(), pid() | nil, String.t(), keyword()) ::
          {:ok, Handle.t()} | {:error, term()}
  def start_background_subagent(manager, parent_session_pid, task, opts)
      when (is_pid(parent_session_pid) or is_nil(parent_session_pid)) and is_binary(task) do
    GenServer.call(manager, {:start_background_subagent, parent_session_pid, task, opts})
  end

  @doc "Lists background sub-agents for a parent session pid, or all background sub-agents when parent is nil."
  @spec list_background_subagents(pid() | nil) :: [Handle.t()]
  def list_background_subagents(parent_session_pid \\ nil) do
    list_background_subagents(__MODULE__, parent_session_pid)
  end

  @doc "Lists background sub-agents through the given manager."
  @spec list_background_subagents(GenServer.server(), pid() | nil) :: [Handle.t()]
  def list_background_subagents(manager, parent_session_pid) do
    GenServer.call(manager, {:list_background_subagents, parent_session_pid})
  end

  @doc "Stops a session by its human-readable ID."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) when is_binary(session_id) do
    stop_session(__MODULE__, session_id)
  end

  @doc "Stops a session by its human-readable ID through the given manager."
  @spec stop_session(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def stop_session(manager, session_id) when is_binary(session_id) do
    GenServer.call(manager, {:stop_session, session_id})
  end

  @doc "Sends a user prompt to a session by ID."
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
  def send_prompt(session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    send_prompt(__MODULE__, session_id, prompt)
  end

  @doc "Sends a user prompt to a session by ID through the given manager."
  @spec send_prompt(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_prompt(manager, session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    GenServer.call(manager, {:send_prompt, session_id, prompt})
  end

  @doc "Aborts the current operation on a session by ID."
  @spec abort(String.t()) :: :ok | {:error, :not_found}
  def abort(session_id) when is_binary(session_id) do
    abort(__MODULE__, session_id)
  end

  @doc "Aborts the current operation on a session by ID through the given manager."
  @spec abort(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def abort(manager, session_id) when is_binary(session_id) do
    GenServer.call(manager, {:abort, session_id})
  end

  @doc "Lists all active sessions as `{id, pid, metadata}` tuples."
  @spec list_sessions() :: [{String.t(), pid(), SessionMetadata.t()}]
  def list_sessions do
    list_sessions(__MODULE__)
  end

  @doc "Lists all active sessions through the given manager."
  @spec list_sessions(GenServer.server()) :: [{String.t(), pid(), SessionMetadata.t()}]
  def list_sessions(manager) do
    GenServer.call(manager, :list_sessions)
  end

  @doc "Looks up the PID for a session ID."
  @spec get_session(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_session(session_id) when is_binary(session_id) do
    get_session(__MODULE__, session_id)
  end

  @doc "Looks up the PID for a session ID through the given manager."
  @spec get_session(GenServer.server(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_session(manager, session_id) when is_binary(session_id) do
    GenServer.call(manager, {:get_session, session_id})
  end

  @doc "Looks up the session ID for a PID."
  @spec session_id_for_pid(pid()) :: {:ok, String.t()} | {:error, :not_found}
  def session_id_for_pid(pid) when is_pid(pid) do
    session_id_for_pid(__MODULE__, pid)
  end

  @doc "Looks up the session ID for a PID through the given manager."
  @spec session_id_for_pid(GenServer.server(), pid()) :: {:ok, String.t()} | {:error, :not_found}
  def session_id_for_pid(manager, pid) when is_pid(pid) do
    GenServer.call(manager, {:session_id_for_pid, pid})
  end

  @doc "Stops a session by its PID (looks up the ID internally)."
  @spec stop_session_by_pid(pid()) :: :ok | {:error, :not_found}
  def stop_session_by_pid(pid) when is_pid(pid) do
    stop_session_by_pid(__MODULE__, pid)
  end

  @doc "Stops a session by its PID through the given manager."
  @spec stop_session_by_pid(GenServer.server(), pid()) :: :ok | {:error, :not_found}
  def stop_session_by_pid(manager, pid) when is_pid(pid) do
    GenServer.call(manager, {:stop_session_by_pid, pid})
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    {:ok, %{sessions: %{}, background_subagents: %{}, next_id: 1}}
  end

  @impl GenServer
  def handle_call({:start_session, opts}, _from, state) do
    case start_managed_session(state, opts) do
      {:ok, session_id, pid, new_state} ->
        {:reply, {:ok, session_id, pid}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_background_subagent, parent_session_pid, task, opts}, _from, state) do
    case Keyword.fetch(opts, :session_opts) do
      {:ok, session_opts} ->
        start_background_subagent_session(state, parent_session_pid, task, opts, session_opts)

      :error ->
        {:reply, {:error, :missing_session_opts}, state}
    end
  end

  def handle_call({:list_background_subagents, parent_session_pid}, _from, state) do
    handles =
      state.background_subagents
      |> Map.values()
      |> filter_background_subagents(parent_session_pid)
      |> Enum.sort_by(& &1.started_at, {:asc, DateTime})

    {:reply, handles, state}
  end

  def handle_call({:stop_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{pid: pid, monitor_ref: ref}} ->
        Process.demonitor(ref, [:flush])
        MingaAgent.Supervisor.stop_session(pid)
        sessions = Map.delete(state.sessions, session_id)
        background_subagents = Map.delete(state.background_subagents, session_id)
        Minga.Log.info(:agent, "[SessionManager] Stopped session #{session_id}")
        {:reply, :ok, %{state | sessions: sessions, background_subagents: background_subagents}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:send_prompt, session_id, prompt}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{pid: pid}} ->
        result = Session.send_prompt(pid, prompt)
        {:reply, result, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:abort, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{pid: pid}} ->
        Session.abort(pid)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_sessions, _from, state) do
    entries =
      Enum.map(state.sessions, fn {session_id, %{pid: pid}} ->
        metadata = safe_metadata(pid)
        {session_id, pid, metadata}
      end)

    {:reply, entries, state}
  end

  def handle_call({:get_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{pid: pid}} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:stop_session_by_pid, pid}, _from, state) do
    case find_session_by_pid(state.sessions, pid) do
      {session_id, %{monitor_ref: ref}} ->
        Process.demonitor(ref, [:flush])
        MingaAgent.Supervisor.stop_session(pid)
        sessions = Map.delete(state.sessions, session_id)
        background_subagents = Map.delete(state.background_subagents, session_id)
        Minga.Log.info(:agent, "[SessionManager] Stopped session #{session_id} (by pid)")
        {:reply, :ok, %{state | sessions: sessions, background_subagents: background_subagents}}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:session_id_for_pid, pid}, _from, state) do
    result =
      Enum.find_value(state.sessions, {:error, :not_found}, fn
        {session_id, %{pid: ^pid}} -> {:ok, session_id}
        _ -> nil
      end)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_session_by_ref(state.sessions, ref) do
      {session_id, _entry} ->
        Minga.Log.info(
          :agent,
          "[SessionManager] Session #{session_id} (#{inspect(pid)}) stopped: #{inspect(reason)}"
        )

        broadcast_session_stopped(session_id, pid, reason)
        sessions = Map.delete(state.sessions, session_id)
        background_subagents = Map.delete(state.background_subagents, session_id)
        {:noreply, %{state | sessions: sessions, background_subagents: background_subagents}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:send_background_prompt, session_id, task, attempt}, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{pid: pid}} ->
        state = send_background_prompt(state, session_id, pid, task, attempt)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec start_background_subagent_session(state(), pid() | nil, String.t(), keyword(), keyword()) ::
          {:reply, {:ok, Handle.t()} | {:error, term()}, state()}
  defp start_background_subagent_session(state, parent_session_pid, task, opts, session_opts) do
    session_opts = Keyword.put(session_opts, :background_subagent, true)

    case start_managed_session(state, session_opts) do
      {:ok, session_id, pid, new_state} ->
        handle =
          Handle.new(
            session_id: session_id,
            pid: pid,
            parent_session_id: parent_session_id(new_state, parent_session_pid),
            parent_pid: parent_session_pid,
            task: task,
            model: Keyword.get(opts, :model),
            started_at: DateTime.utc_now()
          )

        new_state = %{
          new_state
          | background_subagents: Map.put(new_state.background_subagents, session_id, handle)
        }

        broadcast_background_subagent_started(handle)
        send(self(), {:send_background_prompt, session_id, task, 0})
        {:reply, {:ok, handle}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec start_managed_session(state(), keyword()) ::
          {:ok, String.t(), pid(), state()} | {:error, term()}
  defp start_managed_session(state, opts) do
    session_id = "session-#{state.next_id}"
    opts = Keyword.put_new(opts, :session_id, session_id)

    case MingaAgent.Supervisor.start_session(opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        entry = %{pid: pid, monitor_ref: ref}
        sessions = Map.put(state.sessions, session_id, entry)
        new_state = %{state | sessions: sessions, next_id: state.next_id + 1}

        Minga.Log.info(:agent, "[SessionManager] Started session #{session_id} (#{inspect(pid)})")
        {:ok, session_id, pid, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @background_prompt_retry_ms 10
  @background_prompt_max_attempts 100

  @spec send_background_prompt(state(), String.t(), pid(), String.t(), non_neg_integer()) ::
          state()
  defp send_background_prompt(state, session_id, pid, task, attempt) do
    case Session.send_prompt(pid, task) do
      :ok ->
        state

      {:error, :provider_not_ready} when attempt < @background_prompt_max_attempts ->
        Process.send_after(
          self(),
          {:send_background_prompt, session_id, task, attempt + 1},
          @background_prompt_retry_ms
        )

        state

      {:error, reason} ->
        Session.add_system_message(
          pid,
          "Background sub-agent failed to start: #{inspect(reason)}",
          :error
        )

        state
    end
  end

  @spec parent_session_id(state(), pid() | nil) :: String.t() | nil
  defp parent_session_id(_state, nil), do: nil

  defp parent_session_id(state, parent_pid) when is_pid(parent_pid) do
    case find_session_by_pid(state.sessions, parent_pid) do
      {session_id, _entry} -> session_id
      nil -> safe_session_id(parent_pid)
    end
  end

  @spec safe_session_id(pid()) :: String.t() | nil
  defp safe_session_id(pid) do
    Session.session_id(pid)
  catch
    :exit, _ -> nil
  end

  @spec filter_background_subagents([Handle.t()], pid() | nil) :: [Handle.t()]
  defp filter_background_subagents(handles, nil), do: handles

  defp filter_background_subagents(handles, parent_pid) when is_pid(parent_pid) do
    Enum.filter(handles, &(&1.parent_pid == parent_pid))
  end

  @spec broadcast_background_subagent_started(Handle.t()) :: :ok
  defp broadcast_background_subagent_started(%Handle{} = handle) do
    Minga.Events.broadcast(:background_subagent_started, handle)
  end

  @spec find_session_by_ref(%{String.t() => session_entry()}, reference()) ::
          {String.t(), session_entry()} | nil
  defp find_session_by_ref(sessions, ref) do
    Enum.find(sessions, fn {_id, entry} -> entry.monitor_ref == ref end)
  end

  @spec find_session_by_pid(%{String.t() => session_entry()}, pid()) ::
          {String.t(), session_entry()} | nil
  defp find_session_by_pid(sessions, pid) do
    Enum.find(sessions, fn {_id, entry} -> entry.pid == pid end)
  end

  @spec broadcast_session_stopped(String.t(), pid(), term()) :: :ok
  defp broadcast_session_stopped(session_id, pid, reason) do
    Minga.Events.broadcast(
      :agent_session_stopped,
      %SessionStoppedEvent{session_id: session_id, pid: pid, reason: reason}
    )
  end

  @spec safe_metadata(pid()) :: SessionMetadata.t()
  defp safe_metadata(pid) do
    Session.metadata(pid)
  catch
    :exit, _ ->
      now = DateTime.utc_now()

      %SessionMetadata{
        id: "unknown",
        model_name: "unknown",
        created_at: now,
        last_message_at: now
      }
  end
end
