defmodule MingaEditor.Collab.SessionManager do
  @moduledoc """
  Dynamic supervisor and lifecycle API for collab editor sessions.

  Each attached client gets an independent editor session: a triad of
  `MingaEditor.Frontend.Manager` + `MingaEditor.Renderer.Server` + `MingaEditor`
  supervised by a `MingaEditor.Collab.SessionSupervisor`. Sessions share the
  node-local `Minga.Buffer.Registry`, so two sessions opening the same path
  resolve to one `Minga.Buffer.Process`.

  ## Default session

  The default/singleton session is the one started by the static supervision
  tree in interactive mode. It is registered under bare module names and is not
  managed by this dynamic supervisor; `start_session/1` for a non-default id
  spins up an additional triad alongside it.
  """

  use DynamicSupervisor

  alias MingaEditor.Collab.Names
  alias MingaEditor.Collab.SessionSupervisor

  @typedoc "Options for starting a session triad."
  @type start_opt :: SessionSupervisor.start_opt()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a session triad for `session_id`.

  Idempotent: if a triad is already running for `session_id` (or `session_id` is
  the default session, whose triad lives in the static tree), returns
  `{:ok, pid}` for the existing supervisor. Backend defaults to `:tui`.
  """
  @spec start_session(Names.session_id(), [start_opt()]) ::
          {:ok, pid()} | {:error, term()}
  def start_session(session_id, opts \\ []) when is_binary(session_id) do
    cond do
      Names.default_session?(session_id) ->
        existing_default()

      pid = whereis_session(session_id) ->
        {:ok, pid}

      true ->
        opts = Keyword.put(opts, :session_id, session_id)

        case DynamicSupervisor.start_child(__MODULE__, {SessionSupervisor, opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  Stops the session triad for `session_id` and cleans up its contributions.

  Never tears down the default session. Returns `:ok` whether or not a triad was
  running so detach is safe to call repeatedly.
  """
  @spec stop_session(Names.session_id()) :: :ok
  def stop_session(session_id) when is_binary(session_id) do
    if Names.default_session?(session_id) do
      :ok
    else
      cleanup_session(session_id)

      case whereis_session(session_id) do
        nil ->
          :ok

        pid ->
          DynamicSupervisor.terminate_child(__MODULE__, pid)
          :ok
      end
    end
  end

  @doc "Resolves the live triad supervisor pid for `session_id`, or nil."
  @spec whereis_session(Names.session_id()) :: pid() | nil
  def whereis_session(session_id) when is_binary(session_id) do
    GenServer.whereis(SessionSupervisor.supervisor_name(session_id))
  end

  @doc "Returns true when a live editor is registered for `session_id`."
  @spec session_running?(Names.session_id()) :: boolean()
  def session_running?(session_id) when is_binary(session_id) do
    case Names.whereis(session_id, :editor) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @spec existing_default() :: {:ok, pid()} | {:error, :not_running}
  defp existing_default do
    case GenServer.whereis(SessionSupervisor.supervisor_name(Names.default_session_id())) do
      nil -> {:error, :not_running}
      pid -> {:ok, pid}
    end
  end

  @spec cleanup_session(Names.session_id()) :: :ok
  defp cleanup_session(session_id) do
    # Per-session contribution cleanup so extension/sidebar/feature-state
    # contributions don't leak across sessions when a client detaches.
    MingaEditor.Collab.Cleanup.cleanup(session_id)
  end
end
