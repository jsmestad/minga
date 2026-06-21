defmodule MingaAgent.ReactiveDiagnostics do
  @moduledoc """
  Posts an agent chat suggestion when a save introduces a new LSP error.

  This is intentionally one concrete reactive surface, not a generic rule engine.
  """

  use GenServer

  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.Events
  alias Minga.LSP.SyncServer
  alias MingaAgent.Session
  alias MingaAgent.SessionManager

  @save_window_ms 5_000
  @rate_limit_ms 10_000

  @type fingerprint ::
          {non_neg_integer(), non_neg_integer(), String.t(), String.t() | nil, term()}

  @type pending_save :: %{
          path: String.t(),
          baseline: MapSet.t(fingerprint()),
          saved_at_ms: integer()
        }

  @type notification :: %{fingerprint: fingerprint(), at_ms: integer()}

  @type state :: %{
          events_registry: Events.registry(),
          diagnostics_server: GenServer.server(),
          config_server: Options.server(),
          session_manager: GenServer.server(),
          post_fun: (String.t(), GenServer.server() -> :ok),
          now_fun: (-> integer()),
          save_window_ms: non_neg_integer(),
          rate_limit_ms: non_neg_integer(),
          pending: %{String.t() => pending_save()},
          last_notified: %{String.t() => notification()}
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    events_registry = Keyword.get(opts, :events_registry, Events.default_registry())
    Events.subscribe(:buffer_saved, registry: events_registry)
    Events.subscribe(:diagnostics_updated, registry: events_registry)

    {:ok,
     %{
       events_registry: events_registry,
       diagnostics_server: Keyword.get(opts, :diagnostics_server, Diagnostics),
       config_server: Keyword.get(opts, :config_server, Options.default_server()),
       session_manager: Keyword.get(opts, :session_manager, SessionManager),
       post_fun: Keyword.get(opts, :post_fun, &post_to_latest_session/2),
       now_fun: Keyword.get(opts, :now_fun, &monotonic_now_ms/0),
       save_window_ms: Keyword.get(opts, :save_window_ms, @save_window_ms),
       rate_limit_ms: Keyword.get(opts, :rate_limit_ms, @rate_limit_ms),
       pending: %{},
       last_notified: %{}
     }}
  end

  @impl true
  def handle_info(
        {:minga_event, :buffer_saved, %Events.BufferEvent{path: path}},
        state
      ) do
    state = prune_pending(state)

    if enabled?(state) do
      uri = SyncServer.path_to_uri(path)
      baseline = current_error_fingerprints(state, uri)

      pending =
        Map.put(state.pending, uri, %{
          path: path,
          baseline: baseline,
          saved_at_ms: state.now_fun.()
        })

      {:noreply, %{state | pending: pending}}
    else
      {:noreply, %{state | pending: %{}}}
    end
  end

  def handle_info(
        {:minga_event, :diagnostics_updated, %Events.DiagnosticsUpdatedEvent{uri: uri}},
        state
      ) do
    state = prune_pending(state)

    if enabled?(state) do
      {:noreply, maybe_notify_new_error(state, uri)}
    else
      {:noreply, %{state | pending: %{}}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec maybe_notify_new_error(state(), String.t()) :: state()
  defp maybe_notify_new_error(%{pending: pending} = state, uri) do
    case Map.fetch(pending, uri) do
      {:ok, pending_save} ->
        notify_new_error(state, uri, pending_save)

      :error ->
        state
    end
  end

  @spec notify_new_error(state(), String.t(), pending_save()) :: state()
  defp notify_new_error(state, uri, pending_save) do
    current = current_error_fingerprints(state, uri)

    case Enum.find(current, &(not MapSet.member?(pending_save.baseline, &1))) do
      nil ->
        state

      fingerprint ->
        maybe_post_suggestion(state, uri, pending_save.path, fingerprint)
    end
  end

  @spec maybe_post_suggestion(state(), String.t(), String.t(), fingerprint()) :: state()
  defp maybe_post_suggestion(state, uri, path, fingerprint) do
    now = state.now_fun.()
    notification = Map.get(state.last_notified, uri)
    maybe_post_suggestion(state, uri, path, fingerprint, notification, now, state.rate_limit_ms)
  end

  @spec maybe_post_suggestion(
          state(),
          String.t(),
          String.t(),
          fingerprint(),
          notification() | nil,
          integer(),
          non_neg_integer()
        ) :: state()
  defp maybe_post_suggestion(
         state,
         _uri,
         _path,
         fingerprint,
         %{fingerprint: fingerprint},
         _now,
         _rate_limit_ms
       ),
       do: state

  defp maybe_post_suggestion(
         state,
         _uri,
         _path,
         _fingerprint,
         %{at_ms: at_ms},
         now,
         rate_limit_ms
       )
       when now - at_ms < rate_limit_ms,
       do: state

  defp maybe_post_suggestion(state, uri, path, fingerprint, _notification, now, _rate_limit_ms) do
    post_suggestion(state, path, fingerprint)
    last_notified = Map.put(state.last_notified, uri, %{fingerprint: fingerprint, at_ms: now})
    %{state | last_notified: last_notified}
  end

  @spec post_suggestion(state(), String.t(), fingerprint()) :: :ok
  defp post_suggestion(state, path, fingerprint) do
    state.post_fun.(suggestion_text(path, fingerprint), state.session_manager)
  end

  @spec suggestion_text(String.t(), fingerprint()) :: String.t()
  defp suggestion_text(path, {line, col, message, _source, _code}) do
    rel = Path.relative_to_cwd(path)

    "New LSP error after save in #{rel}:#{line + 1}:#{col + 1}: #{message}\n\nAsk me to apply a fix, open chat to discuss it, or ignore this suggestion to dismiss it."
  end

  @spec current_error_fingerprints(state(), String.t()) :: MapSet.t(fingerprint())
  defp current_error_fingerprints(state, uri) do
    state.diagnostics_server
    |> Diagnostics.for_uri(uri)
    |> Enum.filter(&(&1.severity == :error))
    |> Enum.map(&fingerprint/1)
    |> MapSet.new()
  end

  @spec fingerprint(Diagnostic.t()) :: fingerprint()
  defp fingerprint(%Diagnostic{} = diagnostic) do
    {
      diagnostic.range.start_line,
      diagnostic.range.start_col,
      diagnostic.message,
      diagnostic.source,
      diagnostic.code
    }
  end

  @spec enabled?(state()) :: boolean()
  defp enabled?(state), do: Options.get(state.config_server, :agent_react_to_lsp_errors_on_save)

  @spec prune_pending(state()) :: state()
  defp prune_pending(state) do
    now = state.now_fun.()

    pending =
      Map.reject(state.pending, fn {_uri, %{saved_at_ms: saved_at_ms}} ->
        now - saved_at_ms > state.save_window_ms
      end)

    %{state | pending: pending}
  end

  @spec post_to_latest_session(String.t(), GenServer.server()) :: :ok
  defp post_to_latest_session(text, session_manager) do
    case SessionManager.list_sessions(session_manager) do
      [] ->
        :ok

      sessions ->
        sessions
        |> Enum.max_by(fn {_id, _pid, metadata} ->
          DateTime.to_unix(metadata.last_message_at, :microsecond)
        end)
        |> post_to_session(text)
    end
  catch
    :exit, _ -> :ok
  end

  @spec post_to_session({String.t(), pid(), MingaAgent.SessionMetadata.t()} | nil, String.t()) ::
          :ok
  defp post_to_session(nil, _text), do: :ok

  defp post_to_session({_id, pid, _metadata}, text),
    do: Session.add_system_message(pid, text, :info)

  @spec monotonic_now_ms() :: integer()
  defp monotonic_now_ms, do: System.monotonic_time(:millisecond)
end
