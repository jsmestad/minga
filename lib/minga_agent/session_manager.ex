defmodule MingaAgent.SessionManager do
  @moduledoc """
  Owns agent session lifecycle independently of any UI.

  Maps stable session IDs to session PIDs. Local scratch sessions still use
  human-readable generated IDs (e.g., `"session-1"`), while remote attach sessions
  pass a deterministic `:session_id` derived from their server-side working directory.
  Sessions are started via `MingaAgent.Supervisor` (DynamicSupervisor) and
  monitored here. When a session dies or restarts, the manager broadcasts
  lifecycle events so the Editor (or any subscriber) can react without
  monitoring PIDs directly.
  """

  use GenServer

  alias MingaAgent.Session
  alias MingaAgent.SessionMetadata
  alias MingaAgent.SessionStore
  alias MingaAgent.Subagent.Handle

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Internal state of the SessionManager."
  @type state :: %{
          sessions: %{String.t() => session_entry()},
          background_subagents: %{String.t() => Handle.t()},
          next_id: pos_integer()
        }

  @typedoc "Restart bookkeeping for a managed session that is being recovered."
  @type restart_state :: %{
          attempts: pos_integer(),
          window_started_at_ms: integer(),
          timer_ref: reference() | nil,
          timer_token: reference() | nil,
          old_pid: pid(),
          reason: term()
        }

  @typedoc "An entry in the sessions map."
  @type session_entry :: %{
          pid: pid(),
          monitor_ref: reference() | nil,
          token: String.t(),
          restart_opts: keyword(),
          restart_state: restart_state() | nil
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

  defmodule SessionRestartedEvent do
    @moduledoc "Payload for `:agent_session_restarted` events."
    @enforce_keys [:session_id, :old_pid, :new_pid, :reason]
    defstruct [:session_id, :old_pid, :new_pid, :reason]

    @type t :: %__MODULE__{
            session_id: String.t(),
            old_pid: pid(),
            new_pid: pid(),
            reason: term()
          }
  end

  @restart_default_base_delay_ms 10
  @restart_default_max_delay_ms 100
  @restart_default_max_attempts 3
  @restart_default_window_ms 60_000

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

  @doc "Starts or returns the stable session with the given ID."
  @spec start_or_get_session(String.t(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_or_get_session(session_id, opts \\ []) when is_binary(session_id) do
    start_or_get_session(__MODULE__, session_id, opts)
  end

  @doc "Starts or returns the stable session with the given ID through the given manager."
  @spec start_or_get_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start_or_get_session(manager, session_id, opts) when is_binary(session_id) do
    GenServer.call(manager, {:start_or_get_session, session_id, opts})
  end

  @doc "Builds the deterministic session ID used for a server-side working directory."
  @spec stable_session_id_for_workdir(String.t()) :: String.t()
  def stable_session_id_for_workdir(path) when is_binary(path) do
    expanded = Path.expand(path)
    digest = :crypto.hash(:sha256, expanded) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "workdir-#{digest}"
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

  @doc "Returns the broker token for a live session. Used by the remote API bootstrap path."
  @spec session_token(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def session_token(session_id) when is_binary(session_id) do
    session_token(__MODULE__, session_id)
  end

  @doc "Returns the broker token for a live session through the given manager."
  @spec session_token(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def session_token(manager, session_id) when is_binary(session_id) do
    GenServer.call(manager, {:session_token, session_id})
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
      {:existing, session_id, pid, state} ->
        {:reply, {:ok, session_id, pid}, state}

      {:ok, session_id, pid, new_state} ->
        {:reply, {:ok, session_id, pid}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_or_get_session, session_id, opts}, _from, state) do
    opts = Keyword.put(opts, :session_id, session_id)

    case start_managed_session(state, opts) do
      {:existing, session_id, pid, state} ->
        {:reply, {:ok, session_id, pid}, state}

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
      {:ok, %{monitor_ref: ref, pid: pid}} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        MingaAgent.Supervisor.stop_session(pid)
        {:reply, :ok, remove_session(state, session_id)}

      {:ok, %{monitor_ref: nil, restart_state: %{timer_ref: timer_ref}}} ->
        Process.cancel_timer(timer_ref)
        {:reply, :ok, remove_session(state, session_id)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:send_prompt, session_id, prompt}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{monitor_ref: ref, pid: pid}} when is_reference(ref) ->
        result = Session.send_prompt(pid, prompt)
        {:reply, result, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:abort, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{monitor_ref: ref, pid: pid}} when is_reference(ref) ->
        Session.abort(pid)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_sessions, _from, state) do
    entries =
      state.sessions
      |> Enum.filter(fn {_session_id, entry} -> active_session_entry?(entry) end)
      |> Enum.map(fn {session_id, %{pid: pid}} ->
        metadata = safe_metadata(pid)
        {session_id, pid, metadata}
      end)

    {:reply, entries, state}
  end

  def handle_call({:get_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{monitor_ref: ref, pid: pid}} when is_reference(ref) -> {:reply, {:ok, pid}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:session_token, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{monitor_ref: ref, token: token}} when is_reference(ref) ->
        {:reply, {:ok, token}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:stop_session_by_pid, pid}, _from, state) do
    case find_session_by_pid(state.sessions, pid) do
      {session_id, %{monitor_ref: ref}} ->
        Process.demonitor(ref, [:flush])
        MingaAgent.Supervisor.stop_session(pid)
        {:reply, :ok, remove_session(state, session_id)}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:session_id_for_pid, pid}, _from, state) do
    result =
      Enum.find_value(state.sessions, {:error, :not_found}, fn
        {session_id, %{monitor_ref: ref, pid: ^pid}} when is_reference(ref) -> {:ok, session_id}
        _ -> nil
      end)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_session_by_ref(state.sessions, ref) do
      {session_id, entry} ->
        if should_restart_session?(reason) do
          handle_session_restart_down(state, session_id, entry, pid, reason)
        else
          Minga.Log.info(
            :agent,
            "[SessionManager] Session #{session_id} (#{inspect(pid)}) stopped: #{inspect(reason)}"
          )

          broadcast_session_stopped(session_id, pid, reason)
          {:noreply, remove_session(state, session_id)}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:restart_session, session_id, timer_token}, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{restart_state: %{timer_token: ^timer_token}} = entry} ->
        handle_session_restart_timeout(state, session_id, entry)

      _ ->
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
      {:existing, _session_id, _pid, _state} ->
        {:reply, {:error, :session_already_exists}, state}

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
          {:ok, String.t(), pid(), state()}
          | {:existing, String.t(), pid(), state()}
          | {:error, term()}
  defp start_managed_session(state, opts) do
    session_id = Keyword.get(opts, :session_id, "session-#{state.next_id}")

    case Map.fetch(state.sessions, session_id) do
      {:ok, %{monitor_ref: ref, pid: pid}} when is_reference(ref) ->
        {:existing, session_id, pid, state}

      {:ok, %{monitor_ref: nil}} ->
        {:error, :restart_pending}

      :error ->
        do_start_managed_session(state, Keyword.put(opts, :session_id, session_id), session_id)
    end
  end

  @spec do_start_managed_session(state(), keyword(), String.t()) ::
          {:ok, String.t(), pid(), state()} | {:error, term()}
  defp do_start_managed_session(state, opts, session_id) do
    token = session_token_for_start(session_id, opts)
    opts = Keyword.put(opts, :remote_token, token)

    case MingaAgent.Supervisor.start_session(opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        entry = %{
          pid: pid,
          monitor_ref: ref,
          token: token,
          restart_opts: opts,
          restart_state: nil
        }

        sessions = Map.put(state.sessions, session_id, entry)
        next_id = next_id_after_start(state, session_id)
        new_state = %{state | sessions: sessions, next_id: next_id}

        Minga.Log.info(:agent, "[SessionManager] Started session #{session_id} (#{inspect(pid)})")
        {:ok, session_id, pid, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec next_id_after_start(state(), String.t()) :: pos_integer()
  defp next_id_after_start(state, "session-" <> _suffix), do: state.next_id + 1
  defp next_id_after_start(state, _session_id), do: state.next_id

  @spec session_token_for_start(String.t(), keyword()) :: String.t()
  defp session_token_for_start(session_id, opts) do
    case Keyword.get(opts, :remote_token) do
      token when is_binary(token) ->
        token

      _ ->
        case stored_session_token(session_id, opts) do
          {:ok, token} ->
            token

          :missing ->
            generate_token()

          {:error, reason} ->
            log_session_store_load_error(session_id, resolved_session_store_dir(opts), reason)
            generate_token()
        end
    end
  end

  @spec stored_session_token(String.t(), keyword()) ::
          {:ok, String.t()} | :missing | {:error, term()}
  defp stored_session_token(session_id, opts) do
    session_store_dir = Keyword.get(opts, :session_store_dir)

    case SessionStore.load(session_id, session_store_dir) do
      {:ok, data} ->
        case Map.get(data, :remote_token) do
          token when is_binary(token) -> {:ok, token}
          _ -> :missing
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec log_session_store_load_error(String.t(), String.t() | nil, term()) :: :ok
  defp log_session_store_load_error(session_id, session_store_dir, reason) do
    message =
      "[SessionManager] Failed to load persisted remote token for session #{session_id} from #{inspect(session_store_dir)}: #{inspect(reason)}"

    case reason do
      :enoent -> Minga.Log.warning(:agent, message)
      _ -> Minga.Log.error(:agent, message)
    end

    :ok
  end

  @spec generate_token() :: String.t()
  defp generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @spec active_session_entry?(session_entry()) :: boolean()
  defp active_session_entry?(%{monitor_ref: ref}) when is_reference(ref), do: true
  defp active_session_entry?(_entry), do: false

  @spec handle_session_restart_down(state(), String.t(), session_entry(), pid(), term()) ::
          {:noreply, state()}
  defp handle_session_restart_down(state, session_id, entry, old_pid, reason) do
    case next_restart_attempt(entry, old_pid, reason) do
      {:ok, entry, delay_ms} ->
        timer_token = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:restart_session, session_id, timer_token},
            delay_ms
          )

        entry = entry |> put_restart_timer(timer_ref, timer_token) |> Map.put(:monitor_ref, nil)
        {:noreply, put_session_entry(state, session_id, entry)}

      :exhausted ->
        Minga.Log.error(
          :agent,
          "[SessionManager] Exhausted restart attempts for session #{session_id} after #{inspect(reason)}"
        )

        broadcast_session_stopped(session_id, old_pid, {:restart_exhausted, reason})
        {:noreply, remove_session(state, session_id)}
    end
  end

  @spec handle_session_restart_timeout(state(), String.t(), session_entry()) ::
          {:noreply, state()}
  defp handle_session_restart_timeout(state, session_id, entry) do
    restart_state = entry.restart_state

    case restart_managed_session(state, session_id, entry) do
      {:ok, new_state, new_pid} ->
        new_state = restore_restarted_session_state(new_state, session_id, new_pid, entry)

        broadcast_session_restarted(
          session_id,
          restart_state.old_pid,
          new_pid,
          restart_state.reason
        )

        {:noreply, new_state}

      {:error, restart_reason, new_state} ->
        Minga.Log.error(
          :agent,
          "[SessionManager] Failed to restart session #{session_id} after #{inspect(restart_state.reason)}: #{inspect(restart_reason)}"
        )

        case next_restart_attempt(
               %{entry | restart_state: %{restart_state | timer_ref: nil, timer_token: nil}},
               restart_state.old_pid,
               {:restart_failed, restart_reason}
             ) do
          {:ok, retry_entry, delay_ms} ->
            timer_token = make_ref()

            timer_ref =
              Process.send_after(
                self(),
                {:restart_session, session_id, timer_token},
                delay_ms
              )

            retry_entry = put_restart_timer(retry_entry, timer_ref, timer_token)
            {:noreply, put_session_entry(new_state, session_id, retry_entry)}

          :exhausted ->
            Minga.Log.error(
              :agent,
              "[SessionManager] Exhausted restart attempts for session #{session_id} while recovering: #{inspect(restart_reason)}"
            )

            broadcast_session_stopped(
              session_id,
              restart_state.old_pid,
              {:restart_exhausted, restart_reason}
            )

            {:noreply, remove_session(new_state, session_id)}
        end
    end
  end

  @spec next_restart_attempt(session_entry(), pid(), term()) ::
          {:ok, session_entry(), non_neg_integer()} | :exhausted
  defp next_restart_attempt(%{restart_opts: opts} = entry, old_pid, reason) do
    now_ms = System.monotonic_time(:millisecond)
    policy = restart_policy(opts)
    current = entry.restart_state

    {attempts, window_started_at_ms} =
      case current do
        %{window_started_at_ms: window_started_at_ms, attempts: attempts}
        when now_ms - window_started_at_ms <= policy.window_ms ->
          {attempts + 1, window_started_at_ms}

        _ ->
          {1, now_ms}
      end

    if attempts > policy.max_attempts do
      :exhausted
    else
      restart_state = %{
        attempts: attempts,
        window_started_at_ms: window_started_at_ms,
        timer_ref: nil,
        timer_token: nil,
        old_pid: old_pid,
        reason: reason
      }

      {:ok, %{entry | restart_state: restart_state}, restart_delay_ms(policy, attempts)}
    end
  end

  @spec put_restart_timer(session_entry(), reference(), reference()) :: session_entry()
  defp put_restart_timer(entry, timer_ref, timer_token) do
    %{
      entry
      | restart_state: %{entry.restart_state | timer_ref: timer_ref, timer_token: timer_token}
    }
  end

  @spec put_session_entry(state(), String.t(), session_entry()) :: state()
  defp put_session_entry(state, session_id, entry) do
    %{state | sessions: Map.put(state.sessions, session_id, entry)}
  end

  @spec remove_session(state(), String.t()) :: state()
  defp remove_session(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{restart_state: %{timer_ref: timer_ref}}} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)

      _ ->
        :ok
    end

    sessions = Map.delete(state.sessions, session_id)
    background_subagents = Map.delete(state.background_subagents, session_id)
    %{state | sessions: sessions, background_subagents: background_subagents}
  end

  @spec restart_policy(keyword()) :: %{
          base_delay_ms: pos_integer(),
          max_attempts: pos_integer(),
          max_delay_ms: pos_integer(),
          window_ms: non_neg_integer()
        }
  defp restart_policy(opts) do
    %{
      base_delay_ms: Keyword.get(opts, :restart_backoff_base_ms, @restart_default_base_delay_ms),
      max_attempts: Keyword.get(opts, :restart_max_attempts, @restart_default_max_attempts),
      max_delay_ms: Keyword.get(opts, :restart_backoff_max_ms, @restart_default_max_delay_ms),
      window_ms: Keyword.get(opts, :restart_window_ms, @restart_default_window_ms)
    }
  end

  @spec restart_delay_ms(
          %{
            base_delay_ms: pos_integer(),
            max_attempts: pos_integer(),
            max_delay_ms: pos_integer(),
            window_ms: non_neg_integer()
          },
          pos_integer()
        ) :: pos_integer()
  defp restart_delay_ms(%{base_delay_ms: base_delay_ms, max_delay_ms: max_delay_ms}, attempts) do
    exponential = base_delay_ms * round(:math.pow(2, attempts - 1))
    min(exponential, max_delay_ms)
  end

  @spec restore_restarted_session_state(state(), String.t(), pid(), session_entry()) :: state()
  defp restore_restarted_session_state(state, session_id, new_pid, entry) do
    restart_state = %{entry.restart_state | timer_ref: nil, timer_token: nil}

    entry = %{
      entry
      | pid: new_pid,
        monitor_ref: Process.monitor(new_pid),
        restart_state: restart_state
    }

    state = put_session_entry(state, session_id, entry)

    background_subagents =
      state.background_subagents
      |> update_background_subagent_pid(session_id, new_pid)
      |> update_background_subagent_parent_pid(restart_state.old_pid, new_pid)

    state = %{state | background_subagents: background_subagents}

    case maybe_restore_persisted_restart(new_pid, session_id, entry.restart_opts) do
      :restored ->
        Minga.Log.info(
          :agent,
          "[SessionManager] Restored persisted state for restarted session #{session_id}"
        )

        state

      :skipped ->
        state

      {:degraded, reason} ->
        log_restart_restore_failure(session_id, entry.restart_opts, reason)
        Session.add_system_message(new_pid, restart_restore_warning_message(reason), :error)
        state
    end
  end

  @spec maybe_restore_persisted_restart(pid(), String.t(), keyword()) ::
          :restored | :skipped | {:degraded, term()}
  defp maybe_restore_persisted_restart(pid, session_id, opts) do
    if Keyword.get(opts, :persist?, true) do
      case Session.load_session(pid, session_id) do
        :ok ->
          :restored

        {:error, reason} ->
          {:degraded, reason}
      end
    else
      Minga.Log.debug(
        :agent,
        "[SessionManager] Restarted session #{session_id} without persisted state (persist?: false)"
      )

      :skipped
    end
  end

  @spec log_restart_restore_failure(String.t(), keyword(), term()) :: :ok
  defp log_restart_restore_failure(session_id, opts, reason) do
    session_store_dir = resolved_session_store_dir(opts)

    message =
      "[SessionManager] Restarted session #{session_id} from #{inspect(session_store_dir)} could not restore prior context: #{inspect(reason)}"

    case reason do
      :enoent -> Minga.Log.warning(:agent, message)
      _ -> Minga.Log.error(:agent, message)
    end

    :ok
  end

  @spec restart_restore_warning_message(term()) :: String.t()
  defp restart_restore_warning_message(reason) do
    "Session restarted after crash, but prior context could not be restored: #{inspect(reason)}"
  end

  @spec resolved_session_store_dir(keyword()) :: String.t()
  defp resolved_session_store_dir(opts) do
    SessionStore.sessions_dir(Keyword.get(opts, :session_store_dir))
  end

  @background_prompt_retry_ms 10
  @background_prompt_max_attempts 100

  @spec send_background_prompt(state(), String.t(), pid(), String.t(), non_neg_integer()) ::
          state()
  defp send_background_prompt(state, session_id, pid, task, attempt) do
    case safe_send_prompt(pid, task) do
      :ok ->
        state

      {:error, :provider_not_ready} when attempt < @background_prompt_max_attempts ->
        schedule_background_prompt_retry(session_id, task, attempt)
        state

      {:exit, _reason} when attempt < @background_prompt_max_attempts ->
        schedule_background_prompt_retry(session_id, task, attempt)
        state

      {:error, reason} ->
        Session.add_system_message(
          pid,
          "Background sub-agent failed to start: #{inspect(reason)}",
          :error
        )

        state

      {:exit, reason} ->
        log_background_prompt_failure(session_id, pid, attempt, reason)
        state
    end
  end

  @spec schedule_background_prompt_retry(String.t(), String.t(), non_neg_integer()) :: :ok
  defp schedule_background_prompt_retry(session_id, task, attempt) do
    Process.send_after(
      self(),
      {:send_background_prompt, session_id, task, attempt + 1},
      @background_prompt_retry_ms
    )

    :ok
  end

  @spec safe_send_prompt(pid(), String.t()) :: :ok | {:error, term()} | {:exit, term()}
  defp safe_send_prompt(pid, task) do
    Session.send_prompt(pid, task)
  catch
    :exit, reason -> {:exit, reason}
  end

  @spec log_background_prompt_failure(String.t(), pid(), non_neg_integer(), term()) :: :ok
  defp log_background_prompt_failure(session_id, pid, attempt, reason) do
    Minga.Log.error(
      :agent,
      "[SessionManager] Background sub-agent #{session_id} (#{inspect(pid)}) failed to accept prompt after #{attempt + 1} attempts: #{inspect(reason)}"
    )

    :ok
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

  @spec restart_managed_session(state(), String.t(), session_entry()) ::
          {:ok, state(), pid()} | {:error, term(), state()}
  defp restart_managed_session(state, _session_id, %{restart_opts: restart_opts}) do
    case MingaAgent.Supervisor.start_session(restart_opts) do
      {:ok, pid} ->
        {:ok, state, pid}

      {:error, restart_reason} ->
        {:error, restart_reason, state}
    end
  end

  @spec update_background_subagent_pid(%{String.t() => Handle.t()}, String.t(), pid()) ::
          %{String.t() => Handle.t()}
  defp update_background_subagent_pid(background_subagents, session_id, pid) do
    case Map.fetch(background_subagents, session_id) do
      {:ok, handle} -> Map.put(background_subagents, session_id, Handle.with_pid(handle, pid))
      :error -> background_subagents
    end
  end

  @spec update_background_subagent_parent_pid(%{String.t() => Handle.t()}, pid(), pid()) ::
          %{String.t() => Handle.t()}
  defp update_background_subagent_parent_pid(background_subagents, old_parent_pid, new_parent_pid) do
    Enum.reduce(background_subagents, background_subagents, fn
      {session_id, %Handle{parent_pid: ^old_parent_pid} = handle}, acc ->
        Map.put(acc, session_id, Handle.with_parent_pid(handle, new_parent_pid))

      _entry, acc ->
        acc
    end)
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
    Enum.find(sessions, fn {_id, entry} ->
      entry.pid == pid and is_reference(entry.monitor_ref)
    end)
  end

  @spec should_restart_session?(term()) :: boolean()
  defp should_restart_session?(:normal), do: false
  defp should_restart_session?(:shutdown), do: false
  defp should_restart_session?({:shutdown, _}), do: false
  defp should_restart_session?(_reason), do: true

  @spec broadcast_session_stopped(String.t(), pid(), term()) :: :ok
  defp broadcast_session_stopped(session_id, pid, reason) do
    Minga.Events.broadcast(
      :agent_session_stopped,
      %SessionStoppedEvent{session_id: session_id, pid: pid, reason: reason}
    )
  end

  @spec broadcast_session_restarted(String.t(), pid(), pid(), term()) :: :ok
  defp broadcast_session_restarted(session_id, old_pid, new_pid, reason) do
    Minga.Events.broadcast(
      :agent_session_restarted,
      %SessionRestartedEvent{
        session_id: session_id,
        old_pid: old_pid,
        new_pid: new_pid,
        reason: reason
      }
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
