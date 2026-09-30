defmodule MingaAgent.SessionManager do
  @moduledoc """
  Owns agent session lifecycle independently of any UI.

  Maps stable session IDs to session PIDs. Local scratch sessions still use
  human-readable generated IDs (e.g., `"session-1"`), while remote attach sessions
  pass a deterministic `:session_id` derived from their server-side working directory.
  Sessions are started via a configurable `DynamicSupervisor`, which defaults
  to `MingaAgent.Supervisor`, and monitored here. When a session dies or
  restarts, the manager broadcasts lifecycle events so the Editor (or any
  subscriber) can react without monitoring PIDs directly.
  """

  use GenServer

  alias MingaAgent.Session
  alias MingaAgent.SessionListing
  alias MingaAgent.SessionStore
  alias MingaAgent.Subagent.Handle

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Internal state of the SessionManager."
  @type state :: %{
          sessions: %{String.t() => session_entry()},
          background_subagents: %{String.t() => Handle.t()},
          identity_reservations: %{String.t() => identity_reservation_entry()},
          identity_reservations_by_owner: %{pid() => String.t()},
          next_id: pos_integer(),
          session_supervisor: GenServer.server(),
          startup_task_supervisor: GenServer.server()
        }
  @type identity_reservation :: {String.t(), reference()}
  @typep identity_reservation_entry :: %{
           owner_pid: pid(),
           source_id: String.t(),
           reference: reference(),
           token: String.t()
         }

  @typep startup_delivery_phase ::
           :pending
           | {:in_flight, String.t(), reference(), Task.ref(), pid()}
           | {:retry_wait, reference(), reference(), reference()}
           | {:indeterminate, reference(), term()}
  @typep startup_delivery :: %{
           reference: reference(),
           prompt: String.t(),
           attempt: non_neg_integer(),
           phase: startup_delivery_phase()
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
          pid: pid() | nil,
          monitor_ref: reference() | nil,
          provider_pid: pid() | nil,
          provider_monitor_ref: reference() | nil,
          effect_worker_refs: %{pid() => reference()},
          token: String.t(),
          restart_opts: keyword(),
          restart_state: restart_state() | nil,
          stop_pending?: boolean(),
          startup_delivery: startup_delivery() | nil
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
  @metadata_listing_timeout_ms 4_500

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

  @doc "Registers the provider and external effect workers owned by a managed Session."
  @spec register_effect_workers(GenServer.server(), pid(), pid(), [pid()]) ::
          :ok | {:error, :session_not_found | :provider_mismatch}
  def register_effect_workers(manager, session_pid, provider_pid, worker_pids) do
    GenServer.call(
      manager,
      {:register_effect_workers, session_pid, provider_pid, worker_pids}
    )
  end

  @doc "Reserves an unused durable ID for the managed Session that calls this API."
  @spec reserve_session_identity(GenServer.server(), String.t()) ::
          {:ok, :unchanged | identity_reservation()}
          | {:error,
             :session_not_managed
             | :session_id_in_use
             | {:remote_token_persistence_failed, term()}}
  def reserve_session_identity(manager, target_id) when is_binary(target_id) do
    GenServer.call(manager, {:reserve_session_identity, target_id}, :infinity)
  end

  @doc "Commits the calling Session's reserved ID and transfers its persisted token."
  @spec commit_session_identity(GenServer.server(), identity_reservation()) ::
          :ok | {:error, :stale_identity_reservation}
  def commit_session_identity(manager, reservation) do
    GenServer.call(manager, {:commit_session_identity, reservation}, :infinity)
  end

  @doc "Releases the calling Session's exact reservation without changing its ID."
  @spec abort_session_identity(GenServer.server(), identity_reservation()) :: :ok
  def abort_session_identity(manager, reservation) do
    GenServer.call(manager, {:abort_session_identity, reservation}, :infinity)
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
    case GenServer.call(manager, {:stop_session, session_id}) do
      {:stop_session, session_supervisor, pid} ->
        MingaAgent.Supervisor.stop_session(session_supervisor, pid)

      result ->
        result
    end
  end

  @doc "Sends a user prompt to a session by ID."
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
  def send_prompt(session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    send_prompt(__MODULE__, session_id, prompt)
  end

  @doc "Sends a user prompt to a session by ID through the given manager."
  @spec send_prompt(GenServer.server(), String.t(), String.t()) ::
          :ok | {:queued, :steering} | {:error, term()}
  def send_prompt(manager, session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    with {:ok, pid} <- get_session(manager, session_id) do
      Session.send_prompt_for_id(pid, session_id, prompt)
    end
  end

  @doc "Aborts the current operation on a session by ID."
  @spec abort(String.t()) :: :ok | {:error, :not_found}
  def abort(session_id) when is_binary(session_id) do
    abort(__MODULE__, session_id)
  end

  @doc "Aborts the current operation on a session by ID through the given manager."
  @spec abort(GenServer.server(), String.t()) :: :ok | {:error, :not_found | :session_id_changed}
  def abort(manager, session_id) when is_binary(session_id) do
    with {:ok, pid} <- get_session(manager, session_id) do
      Session.abort_for_id(pid, session_id)
    end
  end

  @doc "Lists every active registration with available metadata or a safe unavailable reason."
  @spec list_sessions() :: [SessionListing.t()]
  def list_sessions do
    list_sessions(__MODULE__)
  end

  @doc "Lists every active registration through the given manager without treating metadata failure as session death."
  @spec list_sessions(GenServer.server()) :: [SessionListing.t()]
  def list_sessions(manager) do
    manager
    |> GenServer.call(:list_session_registrations)
    |> read_session_listings()
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
    case GenServer.call(manager, {:stop_session_by_pid, pid}) do
      {:stop_session, session_supervisor, session_pid} ->
        MingaAgent.Supervisor.stop_session(session_supervisor, session_pid)

      result ->
        result
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    {:ok,
     %{
       sessions: %{},
       background_subagents: %{},
       identity_reservations: %{},
       identity_reservations_by_owner: %{},
       next_id: 1,
       session_supervisor: Keyword.get(opts, :session_supervisor, MingaAgent.Supervisor),
       startup_task_supervisor:
         Keyword.get(opts, :startup_task_supervisor, Minga.Eval.TaskSupervisor)
     }}
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

  def handle_call(
        {:register_effect_workers, session_pid, provider_pid, worker_pids},
        _from,
        state
      )
      when is_list(worker_pids) do
    case find_session_by_owner_pid(state.sessions, session_pid) do
      {session_id, entry} ->
        case register_effect_workers(entry, provider_pid, worker_pids) do
          {:ok, entry} ->
            {:reply, :ok, put_session_entry(state, session_id, entry)}

          :provider_mismatch ->
            {:reply, {:error, :provider_mismatch}, state}
        end

      nil ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  def handle_call({:reserve_session_identity, target_id}, {owner_pid, _tag}, state) do
    case reserve_managed_identity(state, owner_pid, target_id) do
      {:ok, :unchanged, state} ->
        {:reply, {:ok, :unchanged}, state}

      {:ok, reservation, state} ->
        {:reply, {:ok, reservation}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:commit_session_identity, reservation}, {owner_pid, _tag}, state) do
    case commit_managed_identity(state, owner_pid, reservation) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      :stale -> {:reply, {:error, :stale_identity_reservation}, state}
    end
  end

  def handle_call({:abort_session_identity, reservation}, {owner_pid, _tag}, state) do
    {:reply, :ok, abort_managed_identity(state, owner_pid, reservation)}
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
      {:ok, %{monitor_ref: ref, pid: pid, stop_pending?: false} = entry}
      when is_reference(ref) ->
        entry = %{entry | restart_state: nil, stop_pending?: true}

        {:reply, {:stop_session, state.session_supervisor, pid},
         finish_pending_stop(state, session_id, entry)}

      {:ok, %{monitor_ref: nil} = entry} ->
        entry = cancel_restart_timer(entry)
        entry = %{entry | pid: nil, restart_state: nil, stop_pending?: true}
        {:reply, :ok, finish_pending_stop(state, session_id, entry)}

      {:ok, %{stop_pending?: true}} ->
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_session_registrations, _from, state) do
    registrations =
      state.sessions
      |> Enum.filter(fn {_session_id, entry} -> active_session_entry?(entry) end)
      |> Enum.map(fn {session_id, %{pid: pid}} -> {session_id, pid} end)

    {:reply, registrations, state}
  end

  def handle_call({:get_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{monitor_ref: ref, pid: pid, stop_pending?: false}} when is_reference(ref) ->
        {:reply, {:ok, pid}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:session_token, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{monitor_ref: ref, token: token, stop_pending?: false}}
      when is_reference(ref) ->
        {:reply, {:ok, token}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:stop_session_by_pid, pid}, _from, state) do
    case find_session_by_pid(state.sessions, pid) do
      {session_id, %{pid: ^pid, stop_pending?: false} = entry} ->
        entry = %{entry | restart_state: nil, stop_pending?: true}

        {:reply, {:stop_session, state.session_supervisor, pid},
         finish_pending_stop(state, session_id, entry)}

      {_session_id, %{pid: ^pid, stop_pending?: true}} ->
        {:reply, :ok, state}

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
    handle_process_down(state, ref, pid, reason)
  end

  def handle_info({:session_provider_attached, _session_id, session_pid, provider_pid}, state) do
    case find_session_by_owner_pid(state.sessions, session_pid) do
      {session_id, entry} ->
        if is_reference(entry.provider_monitor_ref) do
          Process.demonitor(entry.provider_monitor_ref, [:flush])
        end

        provider_monitor_ref = Process.monitor(provider_pid)
        entry = %{entry | provider_pid: provider_pid, provider_monitor_ref: provider_monitor_ref}
        {:noreply, put_session_entry(state, session_id, entry)}

      _ ->
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

  def handle_info({:deliver_background_prompt, session_id, delivery_ref}, state) do
    {:noreply, deliver_startup_prompt(state, session_id, delivery_ref)}
  end

  def handle_info(
        {task_ref, {:startup_prompt_result, delivery_ref, expected_id, session_ref, outcome}},
        state
      )
      when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])

    {:noreply,
     handle_startup_prompt_result(
       state,
       task_ref,
       delivery_ref,
       expected_id,
       session_ref,
       outcome
     )}
  end

  def handle_info(
        {:retry_background_prompt, session_id, delivery_ref, session_ref, timer_token},
        state
      ) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{pid: pid, monitor_ref: ^session_ref, startup_delivery: delivery} = entry}
      when is_pid(pid) ->
        case delivery do
          %{
            reference: ^delivery_ref,
            phase: {:retry_wait, ^session_ref, _timer_ref, ^timer_token}
          } ->
            delivery = %{delivery | phase: :pending}
            state = put_session_entry(state, session_id, %{entry | startup_delivery: delivery})
            send(self(), {:deliver_background_prompt, session_id, delivery_ref})
            {:noreply, state}

          _ ->
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec handle_process_down(state(), reference(), pid(), term()) :: {:noreply, state()}
  defp handle_process_down(state, ref, pid, reason) do
    case startup_delivery_for_task_ref(state.sessions, ref) do
      nil ->
        handle_managed_process_down(state, ref, pid, reason)

      {session_id, entry, delivery, expected_id, session_ref, task_pid} ->
        handle_startup_prompt_task_down(
          state,
          session_id,
          entry,
          delivery,
          expected_id,
          session_ref,
          task_pid,
          reason
        )
    end
  end

  @spec handle_startup_prompt_task_down(
          state(),
          String.t(),
          session_entry(),
          startup_delivery(),
          String.t(),
          reference(),
          pid(),
          term()
        ) :: {:noreply, state()}
  defp handle_startup_prompt_task_down(
         state,
         session_id,
         entry,
         delivery,
         expected_id,
         session_ref,
         task_pid,
         reason
       ) do
    delivery = %{
      delivery
      | phase: {:indeterminate, session_ref, {:task_down, reason}}
    }

    Minga.Log.error(
      :agent,
      "[SessionManager] Background sub-agent startup prompt for session #{expected_id} (currently registered as #{session_id}) has unknown outcome after task #{inspect(task_pid)} exited: #{inspect(reason)}"
    )

    state = put_session_entry(state, session_id, %{entry | startup_delivery: delivery})
    {:noreply, state}
  end

  @spec handle_managed_process_down(state(), reference(), pid(), term()) :: {:noreply, state()}
  defp handle_managed_process_down(state, ref, pid, reason) do
    state = abort_owner_identity_reservation(state, pid)

    case find_session_by_ref(state.sessions, ref) do
      {session_id, %{stop_pending?: true} = entry} ->
        entry = reset_startup_delivery_after_down(entry, ref)
        entry = %{entry | pid: nil, monitor_ref: nil}
        {:noreply, finish_pending_stop(state, session_id, entry)}

      {session_id, entry} ->
        handle_session_process_down(state, session_id, entry, ref, pid, reason)

      nil ->
        handle_provider_or_effect_worker_down(state, ref, pid)
    end
  end

  @spec handle_session_process_down(
          state(),
          String.t(),
          session_entry(),
          reference(),
          pid(),
          term()
        ) :: {:noreply, state()}
  defp handle_session_process_down(state, session_id, entry, ref, pid, reason) do
    entry = reset_startup_delivery_after_down(entry, ref)

    if should_restart_session?(reason) do
      handle_session_restart_down(state, session_id, entry, pid, reason)
    else
      Minga.Log.info(
        :agent,
        "[SessionManager] Session #{session_id} (#{inspect(pid)}) stopped: #{inspect(reason)}"
      )

      broadcast_session_stopped(session_id, pid, reason)

      entry = %{
        entry
        | pid: nil,
          monitor_ref: nil,
          restart_state: nil,
          stop_pending?: true
      }

      {:noreply, finish_pending_stop(state, session_id, entry)}
    end
  end

  @spec handle_provider_or_effect_worker_down(state(), reference(), pid()) :: {:noreply, state()}
  defp handle_provider_or_effect_worker_down(state, ref, pid) do
    case find_session_by_provider_ref(state.sessions, ref) do
      nil -> handle_effect_worker_down(state, ref, pid)
      _session -> handle_provider_down(state, ref, pid)
    end
  end

  @spec deliver_startup_prompt(state(), String.t(), reference()) :: state()
  defp deliver_startup_prompt(state, session_id, delivery_ref) do
    case Map.fetch(state.sessions, session_id) do
      {:ok,
       %{
         pid: pid,
         monitor_ref: session_ref,
         startup_delivery: %{reference: ^delivery_ref, phase: :pending} = delivery
       } = entry}
      when is_reference(session_ref) and is_pid(pid) ->
        launch_startup_prompt_task(state, pid, session_id, session_ref, entry, delivery)

      _ ->
        state
    end
  end

  @spec launch_startup_prompt_task(
          state(),
          pid(),
          String.t(),
          reference(),
          session_entry(),
          startup_delivery()
        ) :: state()
  defp launch_startup_prompt_task(state, pid, session_id, session_ref, entry, delivery) do
    case start_startup_prompt_task(state, pid, session_id, session_ref, delivery) do
      {:ok, task} ->
        delivery = %{
          delivery
          | phase: {:in_flight, session_id, session_ref, task.ref, task.pid}
        }

        put_session_entry(state, session_id, %{entry | startup_delivery: delivery})

      {:error, reason} ->
        log_startup_prompt_task_failure(session_id, reason)
        retry_startup_delivery(state, session_id, entry, delivery)
    end
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

        delivery = %{
          reference: make_ref(),
          prompt: task,
          attempt: 0,
          phase: :pending
        }

        entry = Map.fetch!(new_state.sessions, session_id)

        new_state =
          put_session_entry(new_state, session_id, %{entry | startup_delivery: delivery})

        broadcast_background_subagent_started(handle)
        send(self(), {:deliver_background_prompt, session_id, delivery.reference})
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
    {session_id, opts} = session_id_for_start(state, opts)

    case Map.fetch(state.identity_reservations, session_id) do
      {:ok, _reservation} ->
        {:error, :session_id_in_use}

      :error ->
        start_or_get_unreserved_session(state, opts, session_id)
    end
  end

  @spec start_or_get_unreserved_session(state(), keyword(), String.t()) ::
          {:ok, String.t(), pid(), state()}
          | {:existing, String.t(), pid(), state()}
          | {:error, term()}
  defp start_or_get_unreserved_session(state, opts, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{monitor_ref: ref, pid: pid, stop_pending?: false}} when is_reference(ref) ->
        {:existing, session_id, pid, state}

      {:ok, %{monitor_ref: nil}} ->
        {:error, :restart_pending}

      {:ok, %{stop_pending?: true}} ->
        {:error, :restart_pending}

      :error ->
        do_start_managed_session(state, Keyword.put(opts, :session_id, session_id), session_id)
    end
  end

  @spec do_start_managed_session(state(), keyword(), String.t()) ::
          {:ok, String.t(), pid(), state()} | {:error, term()}
  defp do_start_managed_session(state, opts, session_id) do
    {supplied_token, session_opts} = Keyword.pop(opts, :remote_token)
    session_opts = Keyword.put(session_opts, :session_manager, self())

    with {:ok, token} <-
           session_token_for_start(session_id, supplied_token, session_opts),
         {:ok, pid} <-
           MingaAgent.Supervisor.start_session(state.session_supervisor, session_opts) do
      ref = Process.monitor(pid)

      entry = %{
        pid: pid,
        monitor_ref: ref,
        provider_pid: nil,
        provider_monitor_ref: nil,
        effect_worker_refs: %{},
        token: token,
        restart_opts: session_opts,
        restart_state: nil,
        startup_delivery: nil,
        stop_pending?: false
      }

      sessions = Map.put(state.sessions, session_id, entry)
      next_id = next_id_after_start(state, session_id)
      new_state = %{state | sessions: sessions, next_id: next_id}

      Minga.Log.info(
        :agent,
        "[SessionManager] Started session #{session_id} (#{inspect(pid)})"
      )

      {:ok, session_id, pid, new_state}
    end
  end

  @spec session_id_for_start(state(), keyword()) :: {String.t(), keyword()}
  defp session_id_for_start(state, opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, session_id} when is_binary(session_id) ->
        {session_id, opts}

      :error ->
        session_id = generated_session_id(state.next_id)

        {session_id,
         opts
         |> Keyword.put(:session_id, session_id)
         |> Keyword.put_new(:recover_interrupted_work?, false)}
    end
  end

  @spec generated_session_id(pos_integer()) :: String.t()
  defp generated_session_id(index) do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "session-#{index}-#{suffix}"
  end

  @spec next_id_after_start(state(), String.t()) :: pos_integer()
  defp next_id_after_start(state, "session-" <> _suffix), do: state.next_id + 1
  defp next_id_after_start(state, _session_id), do: state.next_id

  @spec session_token_for_start(String.t(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp session_token_for_start(session_id, supplied_token, opts) do
    candidate =
      case supplied_token do
        token when is_binary(token) -> token
        _ -> generate_token()
      end

    if Keyword.get(opts, :persist?, true) do
      establish_persisted_token(session_id, candidate, opts)
    else
      {:ok, candidate}
    end
  end

  @spec establish_persisted_token(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp establish_persisted_token(session_id, candidate, opts) do
    session_store_dir = Keyword.get(opts, :session_store_dir)

    case SessionStore.establish_remote_token(session_id, candidate, session_store_dir) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, {:remote_token_persistence_failed, reason}}
    end
  end

  @spec generate_token() :: String.t()
  defp generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @spec reserve_managed_identity(state(), pid(), String.t()) ::
          {:ok, :unchanged | identity_reservation(), state()} | {:error, term()}
  defp reserve_managed_identity(state, owner_pid, target_id) do
    case find_session_by_owner_pid(state.sessions, owner_pid) do
      {^target_id, _entry} ->
        {:ok, :unchanged, state}

      {source_id, %{monitor_ref: ref, stop_pending?: false} = entry}
      when is_reference(ref) ->
        reserve_target_identity(state, owner_pid, source_id, target_id, entry)

      _ ->
        {:error, :session_not_managed}
    end
  end

  @spec reserve_target_identity(state(), pid(), String.t(), String.t(), session_entry()) ::
          {:ok, identity_reservation(), state()} | {:error, term()}
  defp reserve_target_identity(state, owner_pid, source_id, target_id, entry) do
    available? =
      not Map.has_key?(state.sessions, target_id) and
        not Map.has_key?(state.identity_reservations, target_id) and
        not Map.has_key?(state.identity_reservations_by_owner, owner_pid)

    if available? do
      case session_token_for_start(target_id, nil, entry.restart_opts) do
        {:ok, token} ->
          reservation_ref = make_ref()

          reservation = %{
            owner_pid: owner_pid,
            source_id: source_id,
            reference: reservation_ref,
            token: token
          }

          reservations = Map.put(state.identity_reservations, target_id, reservation)
          owners = Map.put(state.identity_reservations_by_owner, owner_pid, target_id)

          state = %{
            state
            | identity_reservations: reservations,
              identity_reservations_by_owner: owners
          }

          {:ok, {target_id, reservation_ref}, state}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :session_id_in_use}
    end
  end

  @spec commit_managed_identity(state(), pid(), identity_reservation()) ::
          {:ok, state()} | :stale
  defp commit_managed_identity(state, owner_pid, {target_id, reservation_ref}) do
    case Map.fetch(state.identity_reservations, target_id) do
      {:ok,
       %{
         owner_pid: ^owner_pid,
         source_id: source_id,
         reference: ^reservation_ref,
         token: token
       } = reservation} ->
        case Map.fetch(state.sessions, source_id) do
          {:ok, %{pid: ^owner_pid, stop_pending?: false} = entry} ->
            commit_identity_rekey(state, target_id, reservation, entry, token)

          _ ->
            :stale
        end

      _ ->
        :stale
    end
  end

  @spec commit_identity_rekey(
          state(),
          String.t(),
          identity_reservation_entry(),
          session_entry(),
          String.t()
        ) :: {:ok, state()} | :stale
  defp commit_identity_rekey(state, target_id, reservation, entry, token) do
    source_id = reservation.source_id

    if Map.has_key?(state.sessions, target_id) do
      :stale
    else
      entry = %{
        entry
        | token: token,
          restart_opts: Keyword.put(entry.restart_opts, :session_id, target_id)
      }

      entry = reset_startup_delivery_after_rekey(entry)

      sessions = state.sessions |> Map.delete(source_id) |> Map.put(target_id, entry)

      new_state = %{
        state
        | sessions: sessions,
          next_id: next_id_after_start(state, target_id),
          background_subagents:
            rekey_background_subagents(state.background_subagents, source_id, target_id)
      }

      new_state = release_identity_reservation(new_state, target_id, reservation.reference)
      {:ok, schedule_pending_startup_prompt(new_state, target_id)}
    end
  end

  @spec reset_startup_delivery_after_rekey(session_entry()) :: session_entry()
  defp reset_startup_delivery_after_rekey(
         %{startup_delivery: %{phase: {:retry_wait, _session_ref, timer_ref, _token}} = delivery} =
           entry
       ) do
    Process.cancel_timer(timer_ref)
    %{entry | startup_delivery: %{delivery | phase: :pending}}
  end

  defp reset_startup_delivery_after_rekey(entry), do: entry

  @spec abort_managed_identity(state(), pid(), identity_reservation()) :: state()
  defp abort_managed_identity(state, owner_pid, {target_id, reservation_ref}) do
    case Map.fetch(state.identity_reservations, target_id) do
      {:ok, %{owner_pid: ^owner_pid, reference: ^reservation_ref}} ->
        release_identity_reservation(state, target_id, reservation_ref)

      _ ->
        state
    end
  end

  @spec abort_owner_identity_reservation(state(), pid()) :: state()
  defp abort_owner_identity_reservation(state, owner_pid) do
    case Map.fetch(state.identity_reservations_by_owner, owner_pid) do
      {:ok, target_id} ->
        case Map.fetch(state.identity_reservations, target_id) do
          {:ok, %{owner_pid: ^owner_pid, reference: reservation_ref}} ->
            release_identity_reservation(state, target_id, reservation_ref)

          _ ->
            %{
              state
              | identity_reservations_by_owner:
                  Map.delete(state.identity_reservations_by_owner, owner_pid)
            }
        end

      :error ->
        state
    end
  end

  @spec release_identity_reservation(state(), String.t(), reference()) :: state()
  defp release_identity_reservation(state, target_id, reservation_ref) do
    case Map.fetch(state.identity_reservations, target_id) do
      {:ok, %{reference: ^reservation_ref, owner_pid: owner_pid}} ->
        %{
          state
          | identity_reservations: Map.delete(state.identity_reservations, target_id),
            identity_reservations_by_owner:
              Map.delete(state.identity_reservations_by_owner, owner_pid)
        }

      _ ->
        state
    end
  end

  @spec rekey_background_subagents(%{String.t() => Handle.t()}, String.t(), String.t()) ::
          %{String.t() => Handle.t()}
  defp rekey_background_subagents(background_subagents, source_id, target_id) do
    background_subagents =
      case Map.pop(background_subagents, source_id) do
        {nil, remaining} ->
          remaining

        {handle, remaining} ->
          Map.put(remaining, target_id, Handle.with_session_id(handle, target_id))
      end

    Map.new(background_subagents, fn {session_id, handle} ->
      parent_session_id =
        if handle.parent_session_id == source_id, do: target_id, else: handle.parent_session_id

      {session_id, Handle.with_parent_session_id(handle, parent_session_id)}
    end)
  end

  @spec active_session_entry?(session_entry()) :: boolean()
  defp active_session_entry?(%{monitor_ref: ref}) when is_reference(ref), do: true
  defp active_session_entry?(_entry), do: false

  @spec handle_session_restart_down(state(), String.t(), session_entry(), pid(), term()) ::
          {:noreply, state()}
  defp handle_session_restart_down(state, session_id, entry, old_pid, reason) do
    case next_restart_attempt(entry, old_pid, reason) do
      {:ok, entry, delay_ms} ->
        entry = %{entry | monitor_ref: nil}

        if (is_pid(entry.provider_pid) and Process.alive?(entry.provider_pid)) or
             map_size(entry.effect_worker_refs) > 0 do
          {:noreply, put_session_entry(state, session_id, entry)}
        else
          schedule_session_restart(state, session_id, entry, delay_ms)
        end

      :exhausted ->
        Minga.Log.error(
          :agent,
          "[SessionManager] Exhausted restart attempts for session #{session_id} after #{inspect(reason)}"
        )

        broadcast_session_stopped(session_id, old_pid, {:restart_exhausted, reason})
        entry = %{entry | pid: nil, monitor_ref: nil, restart_state: nil, stop_pending?: true}
        {:noreply, finish_pending_stop(state, session_id, entry)}
    end
  end

  @spec schedule_session_restart(state(), String.t(), session_entry(), non_neg_integer()) ::
          {:noreply, state()}
  defp schedule_session_restart(state, session_id, entry, delay_ms) do
    timer_token = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:restart_session, session_id, timer_token},
        delay_ms
      )

    entry = put_restart_timer(entry, timer_ref, timer_token)
    {:noreply, put_session_entry(state, session_id, entry)}
  end

  @spec handle_provider_down(state(), reference(), pid()) :: {:noreply, state()}
  defp handle_provider_down(state, ref, _pid) do
    case find_session_by_provider_ref(state.sessions, ref) do
      {session_id, %{stop_pending?: true} = entry} ->
        entry = %{entry | provider_pid: nil, provider_monitor_ref: nil}
        {:noreply, finish_pending_stop(state, session_id, entry)}

      {session_id, %{monitor_ref: nil, restart_state: %{attempts: _attempts}} = entry} ->
        entry = %{entry | provider_pid: nil, provider_monitor_ref: nil}

        if map_size(entry.effect_worker_refs) == 0 do
          schedule_session_restart(state, session_id, entry, restart_delay_for_entry(entry))
        else
          {:noreply, put_session_entry(state, session_id, entry)}
        end

      {session_id, entry} ->
        entry = %{entry | provider_pid: nil, provider_monitor_ref: nil}
        {:noreply, put_session_entry(state, session_id, entry)}

      nil ->
        {:noreply, state}
    end
  end

  @spec handle_effect_worker_down(state(), reference(), pid()) :: {:noreply, state()}
  defp handle_effect_worker_down(state, ref, _pid) do
    case find_session_by_effect_worker_ref(state.sessions, ref) do
      {session_id, entry} ->
        effect_worker_refs =
          Enum.reject(entry.effect_worker_refs, fn {_worker_pid, worker_ref} ->
            worker_ref == ref
          end)
          |> Map.new()

        entry = %{entry | effect_worker_refs: effect_worker_refs}
        maybe_schedule_after_worker_down(state, session_id, entry)

      nil ->
        {:noreply, state}
    end
  end

  @spec maybe_schedule_after_worker_down(state(), String.t(), session_entry()) ::
          {:noreply, state()}
  defp maybe_schedule_after_worker_down(
         state,
         session_id,
         %{stop_pending?: true} = entry
       ) do
    {:noreply, finish_pending_stop(state, session_id, entry)}
  end

  defp maybe_schedule_after_worker_down(state, session_id, entry) do
    case {entry.monitor_ref, entry.restart_state, map_size(entry.effect_worker_refs)} do
      {nil, %{attempts: _attempts}, 0} ->
        if is_pid(entry.provider_pid) and Process.alive?(entry.provider_pid) do
          {:noreply, put_session_entry(state, session_id, entry)}
        else
          if is_reference(entry.provider_monitor_ref) do
            Process.demonitor(entry.provider_monitor_ref, [:flush])
          end

          entry = %{entry | provider_pid: nil, provider_monitor_ref: nil}
          schedule_session_restart(state, session_id, entry, restart_delay_for_entry(entry))
        end

      _ ->
        {:noreply, put_session_entry(state, session_id, entry)}
    end
  end

  @spec finish_pending_stop(state(), String.t(), session_entry()) :: state()
  defp finish_pending_stop(state, session_id, entry) do
    case {entry.pid, entry.provider_pid, map_size(entry.effect_worker_refs)} do
      {nil, nil, 0} -> remove_session(state, session_id)
      _generation_still_running -> put_session_entry(state, session_id, entry)
    end
  end

  @spec cancel_restart_timer(session_entry()) :: session_entry()
  defp cancel_restart_timer(%{restart_state: %{timer_ref: timer_ref} = restart_state} = entry) do
    if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)
    %{entry | restart_state: %{restart_state | timer_ref: nil, timer_token: nil}}
  end

  defp cancel_restart_timer(entry), do: entry

  @spec register_effect_workers(session_entry(), pid(), [pid()]) ::
          {:ok, session_entry()} | :provider_mismatch
  defp register_effect_workers(%{provider_pid: nil} = entry, provider_pid, worker_pids) do
    entry = %{
      entry
      | provider_pid: provider_pid,
        provider_monitor_ref: Process.monitor(provider_pid)
    }

    register_effect_workers(entry, provider_pid, worker_pids)
  end

  defp register_effect_workers(%{provider_pid: provider_pid} = entry, provider_pid, worker_pids) do
    entry = cancel_restart_timer(entry)

    effect_worker_refs =
      Enum.reduce(worker_pids, entry.effect_worker_refs, fn worker_pid, refs ->
        case Map.fetch(refs, worker_pid) do
          :error -> Map.put(refs, worker_pid, Process.monitor(worker_pid))
          {:ok, _ref} -> refs
        end
      end)

    {:ok, %{entry | effect_worker_refs: effect_worker_refs}}
  end

  defp register_effect_workers(_entry, _provider_pid, _worker_pids), do: :provider_mismatch

  @spec restart_delay_for_entry(session_entry()) :: non_neg_integer()
  defp restart_delay_for_entry(%{restart_opts: opts, restart_state: %{attempts: attempts}}) do
    restart_delay_ms(restart_policy(opts), attempts)
  end

  @spec handle_session_restart_timeout(state(), String.t(), session_entry()) ::
          {:noreply, state()}
  defp handle_session_restart_timeout(state, session_id, entry) do
    entry = cancel_restart_timer(entry)

    if previous_generation_active?(entry) do
      {:noreply, put_session_entry(state, session_id, entry)}
    else
      do_handle_session_restart_timeout(state, session_id, entry)
    end
  end

  @spec previous_generation_active?(session_entry()) :: boolean()
  defp previous_generation_active?(%{provider_pid: provider_pid, effect_worker_refs: workers}) do
    map_size(workers) > 0 or (is_pid(provider_pid) and Process.alive?(provider_pid))
  end

  @spec do_handle_session_restart_timeout(state(), String.t(), session_entry()) ::
          {:noreply, state()}
  defp do_handle_session_restart_timeout(state, session_id, entry) do
    restart_state = entry.restart_state

    case restart_managed_session(state, session_id, entry) do
      {:ok, new_state, new_pid} ->
        new_state = restore_restarted_session_state(new_state, session_id, new_pid, entry)
        new_state = schedule_pending_startup_prompt(new_state, session_id)

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

            terminal_entry = %{
              entry
              | pid: nil,
                monitor_ref: nil,
                restart_state: nil,
                stop_pending?: true
            }

            {:noreply, finish_pending_stop(new_state, session_id, terminal_entry)}
        end
    end
  end

  @spec remove_session(state(), String.t()) :: state()
  defp remove_session(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, entry} ->
        case entry.restart_state do
          %{timer_ref: timer_ref} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
          _restart_state -> :ok
        end

        if is_reference(entry.provider_monitor_ref) do
          Process.demonitor(entry.provider_monitor_ref, [:flush])
        end

        Enum.each(entry.effect_worker_refs, fn {_pid, ref} ->
          Process.demonitor(ref, [:flush])
        end)

      :error ->
        :ok
    end

    sessions = Map.delete(state.sessions, session_id)
    background_subagents = Map.delete(state.background_subagents, session_id)
    %{state | sessions: sessions, background_subagents: background_subagents}
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

  @startup_prompt_retry_base_ms 10
  @startup_prompt_retry_max_ms 1_000
  @background_prompt_call_timeout_ms 30_000

  @spec startup_delivery_for_task_ref(%{String.t() => session_entry()}, term()) ::
          {String.t(), session_entry(), startup_delivery(), String.t(), reference(), pid()}
          | nil
  defp startup_delivery_for_task_ref(sessions, task_ref) do
    Enum.find_value(sessions, fn {session_id, entry} ->
      case entry.startup_delivery do
        %{
          phase: {:in_flight, expected_session_id, session_ref, ^task_ref, task_pid}
        } = delivery ->
          {session_id, entry, delivery, expected_session_id, session_ref, task_pid}

        _ ->
          nil
      end
    end)
  end

  @spec handle_startup_prompt_result(
          state(),
          term(),
          reference(),
          String.t(),
          reference(),
          term()
        ) :: state()
  defp handle_startup_prompt_result(
         state,
         task_ref,
         delivery_ref,
         expected_session_id,
         session_ref,
         outcome
       ) do
    case startup_delivery_for_task_ref(state.sessions, task_ref) do
      {session_id, entry,
       %{
         reference: ^delivery_ref,
         phase: {:in_flight, ^expected_session_id, ^session_ref, _, _}
       } = delivery, _, _, _} ->
        handle_startup_prompt_outcome(
          state,
          session_id,
          expected_session_id,
          entry,
          delivery,
          session_ref,
          outcome
        )

      _ ->
        state
    end
  end

  @spec handle_startup_prompt_outcome(
          state(),
          String.t(),
          String.t(),
          session_entry(),
          startup_delivery(),
          reference(),
          term()
        ) :: state()
  defp handle_startup_prompt_outcome(
         state,
         session_id,
         _expected_session_id,
         %{stop_pending?: true} = entry,
         delivery,
         _session_ref,
         _outcome
       ) do
    clear_startup_delivery(state, session_id, entry, delivery)
  end

  defp handle_startup_prompt_outcome(
         state,
         session_id,
         _expected_session_id,
         entry,
         delivery,
         _session_ref,
         outcome
       )
       when outcome in [:ok, {:queued, :steering}] do
    clear_startup_delivery(state, session_id, entry, delivery)
  end

  defp handle_startup_prompt_outcome(
         state,
         session_id,
         _expected_session_id,
         entry,
         delivery,
         _session_ref,
         {:error, reason}
       )
       when reason in [:provider_not_ready, :credential_discovery_pending, :session_id_changed] do
    retry_startup_delivery(state, session_id, entry, delivery)
  end

  defp handle_startup_prompt_outcome(
         state,
         session_id,
         expected_session_id,
         entry,
         delivery,
         session_ref,
         {:exit, reason}
       ) do
    mark_startup_delivery_indeterminate(
      state,
      session_id,
      expected_session_id,
      entry,
      delivery,
      session_ref,
      {:session_call_exit, reason}
    )
  end

  defp handle_startup_prompt_outcome(
         state,
         session_id,
         expected_session_id,
         entry,
         delivery,
         _session_ref,
         {:error, reason}
       ) do
    state = clear_startup_delivery(state, session_id, entry, delivery)

    Minga.Log.warning(
      :agent,
      "[SessionManager] Background sub-agent startup prompt for session #{expected_session_id} (currently registered as #{session_id}) failed: #{inspect(reason)}"
    )

    case Map.fetch(state.sessions, session_id) do
      {:ok, %{pid: pid, stop_pending?: false}} when is_pid(pid) ->
        Session.add_system_message_for_id(
          pid,
          expected_session_id,
          "Background sub-agent failed to start: #{inspect(reason)}",
          :error
        )

      _ ->
        :ok
    end

    state
  end

  defp handle_startup_prompt_outcome(
         state,
         session_id,
         expected_session_id,
         entry,
         delivery,
         session_ref,
         outcome
       ) do
    mark_startup_delivery_indeterminate(
      state,
      session_id,
      expected_session_id,
      entry,
      delivery,
      session_ref,
      {:unexpected_outcome, outcome}
    )
  end

  @spec clear_startup_delivery(state(), String.t(), session_entry(), startup_delivery()) ::
          state()
  defp clear_startup_delivery(state, session_id, entry, _delivery) do
    put_session_entry(state, session_id, %{entry | startup_delivery: nil})
  end

  @spec retry_startup_delivery(state(), String.t(), session_entry(), startup_delivery()) ::
          state()
  defp retry_startup_delivery(state, session_id, entry, delivery) do
    delivery = %{delivery | attempt: delivery.attempt + 1}

    case {entry.monitor_ref, entry.pid, entry.stop_pending?} do
      {session_ref, pid, false} when is_reference(session_ref) and is_pid(pid) ->
        timer_token = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:retry_background_prompt, session_id, delivery.reference, session_ref, timer_token},
            startup_prompt_retry_delay(delivery.attempt)
          )

        delivery = %{
          delivery
          | phase: {:retry_wait, session_ref, timer_ref, timer_token}
        }

        put_session_entry(state, session_id, %{entry | startup_delivery: delivery})

      _ ->
        put_session_entry(state, session_id, %{
          entry
          | startup_delivery: %{delivery | phase: :pending}
        })
    end
  end

  @spec startup_prompt_retry_delay(non_neg_integer()) :: pos_integer()
  defp startup_prompt_retry_delay(attempt) do
    shift = min(attempt, 7)
    min(@startup_prompt_retry_base_ms * 2 ** shift, @startup_prompt_retry_max_ms)
  end

  @spec mark_startup_delivery_indeterminate(
          state(),
          String.t(),
          String.t(),
          session_entry(),
          startup_delivery(),
          reference(),
          term()
        ) :: state()
  defp mark_startup_delivery_indeterminate(
         state,
         session_id,
         expected_session_id,
         entry,
         delivery,
         session_ref,
         reason
       ) do
    delivery = %{delivery | phase: {:indeterminate, session_ref, reason}}

    Minga.Log.error(
      :agent,
      "[SessionManager] Background sub-agent startup prompt for session #{expected_session_id} (currently registered as #{session_id}) has unknown outcome and will not be retried: #{inspect(reason)}"
    )

    put_session_entry(state, session_id, %{entry | startup_delivery: delivery})
  end

  @spec reset_startup_delivery_after_down(session_entry(), reference()) :: session_entry()
  defp reset_startup_delivery_after_down(
         %{startup_delivery: %{phase: {:retry_wait, session_ref, timer_ref, _token}} = delivery} =
           entry,
         session_ref
       ) do
    Process.cancel_timer(timer_ref)
    %{entry | startup_delivery: %{delivery | phase: :pending}}
  end

  defp reset_startup_delivery_after_down(entry, _session_ref), do: entry

  @spec schedule_pending_startup_prompt(state(), String.t()) :: state()
  defp schedule_pending_startup_prompt(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{startup_delivery: %{reference: delivery_ref, phase: :pending}}} ->
        send(self(), {:deliver_background_prompt, session_id, delivery_ref})
        state

      _ ->
        state
    end
  end

  @spec start_startup_prompt_task(
          state(),
          pid(),
          String.t(),
          reference(),
          startup_delivery()
        ) :: {:ok, Task.t()} | {:error, term()}
  defp start_startup_prompt_task(state, pid, session_id, session_ref, delivery) do
    {:ok,
     Task.Supervisor.async_nolink(state.startup_task_supervisor, fn ->
       outcome = safe_send_prompt_for_id(pid, session_id, delivery.prompt)
       {:startup_prompt_result, delivery.reference, session_id, session_ref, outcome}
     end)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec safe_send_prompt_for_id(pid(), String.t(), String.t()) ::
          :ok | {:queued, :steering} | {:error, term()} | {:exit, term()}
  defp safe_send_prompt_for_id(pid, session_id, prompt) do
    Session.send_prompt_for_id(pid, session_id, prompt, @background_prompt_call_timeout_ms)
  catch
    :exit, reason -> {:exit, reason}
  end

  @spec log_startup_prompt_task_failure(String.t(), term()) :: :ok
  defp log_startup_prompt_task_failure(session_id, reason) do
    Minga.Log.error(
      :agent,
      "[SessionManager] Could not start background sub-agent #{session_id} startup prompt task: #{inspect(reason)}"
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
    case MingaAgent.Supervisor.start_session(state.session_supervisor, restart_opts) do
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

  @spec find_session_by_provider_ref(%{String.t() => session_entry()}, reference()) ::
          {String.t(), session_entry()} | nil
  defp find_session_by_provider_ref(sessions, ref) do
    Enum.find(sessions, fn {_id, entry} -> entry.provider_monitor_ref == ref end)
  end

  @spec find_session_by_effect_worker_ref(%{String.t() => session_entry()}, reference()) ::
          {String.t(), session_entry()} | nil
  defp find_session_by_effect_worker_ref(sessions, ref) do
    Enum.find(sessions, fn {_id, entry} ->
      Enum.any?(entry.effect_worker_refs, fn {_pid, worker_ref} -> worker_ref == ref end)
    end)
  end

  @spec find_session_by_owner_pid(%{String.t() => session_entry()}, pid()) ::
          {String.t(), session_entry()} | nil
  defp find_session_by_owner_pid(sessions, pid) do
    Enum.find(sessions, fn {_id, entry} -> entry.pid == pid end)
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

  @spec read_session_listings([{String.t(), pid()}]) :: [SessionListing.t()]
  defp read_session_listings([]), do: []

  defp read_session_listings(registrations) do
    registrations
    |> Task.async_stream(
      fn {session_id, pid} -> SessionListing.read(session_id, pid) end,
      ordered: true,
      timeout: @metadata_listing_timeout_ms,
      max_concurrency: length(registrations),
      on_timeout: :kill_task
    )
    |> Enum.zip(registrations)
    |> Enum.map(&listing_result/1)
  end

  @spec listing_result({{:ok, SessionListing.t()} | {:exit, term()}, {String.t(), pid()}}) ::
          SessionListing.t()
  defp listing_result({{:ok, listing}, _registration}), do: listing

  defp listing_result({{:exit, :timeout}, {session_id, pid}}),
    do: SessionListing.unavailable(session_id, pid, :timeout)

  defp listing_result({{:exit, _reason}, {session_id, pid}}),
    do: SessionListing.unavailable(session_id, pid, :unreachable)
end
