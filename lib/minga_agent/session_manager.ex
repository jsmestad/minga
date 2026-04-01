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

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Internal state of the SessionManager."
  @type state :: %{
          sessions: %{String.t() => session_entry()},
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
    GenServer.call(__MODULE__, {:start_session, opts})
  end

  @doc "Stops a session by its human-readable ID."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:stop_session, session_id})
  end

  @doc "Sends a user prompt to a session by ID."
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
  def send_prompt(session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    GenServer.call(__MODULE__, {:send_prompt, session_id, prompt})
  end

  @doc "Aborts the current operation on a session by ID."
  @spec abort(String.t()) :: :ok | {:error, :not_found}
  def abort(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:abort, session_id})
  end

  @doc "Lists all active sessions as `{id, pid, metadata}` tuples."
  @spec list_sessions() :: [{String.t(), pid(), SessionMetadata.t()}]
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  @doc "Looks up the PID for a session ID."
  @spec get_session(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  @doc "Looks up the session ID for a PID."
  @spec session_id_for_pid(pid()) :: {:ok, String.t()} | {:error, :not_found}
  def session_id_for_pid(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:session_id_for_pid, pid})
  end

  @doc "Stops a session by its PID (looks up the ID internally)."
  @spec stop_session_by_pid(pid()) :: :ok | {:error, :not_found}
  def stop_session_by_pid(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:stop_session_by_pid, pid})
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    {:ok, %{sessions: %{}, next_id: 1}}
  end

  @impl GenServer
  def handle_call({:start_session, opts}, _from, state) do
    session_id = "session-#{state.next_id}"

    case MingaAgent.Supervisor.start_session(opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        entry = %{pid: pid, monitor_ref: ref}
        sessions = Map.put(state.sessions, session_id, entry)
        new_state = %{state | sessions: sessions, next_id: state.next_id + 1}

        Minga.Log.info(:agent, "[SessionManager] Started session #{session_id} (#{inspect(pid)})")
        {:reply, {:ok, session_id, pid}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{pid: pid, monitor_ref: ref}} ->
        Process.demonitor(ref, [:flush])
        MingaAgent.Supervisor.stop_session(pid)
        sessions = Map.delete(state.sessions, session_id)
        Minga.Log.info(:agent, "[SessionManager] Stopped session #{session_id}")
        {:reply, :ok, %{state | sessions: sessions}}

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
        Minga.Log.info(:agent, "[SessionManager] Stopped session #{session_id} (by pid)")
        {:reply, :ok, %{state | sessions: sessions}}

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
        {:noreply, %{state | sessions: sessions}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

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
      %SessionMetadata{
        id: "unknown",
        model_name: "unknown",
        created_at: DateTime.utc_now()
      }
  end
end
