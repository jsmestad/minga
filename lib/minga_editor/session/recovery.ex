defmodule MingaEditor.Session.Recovery do
  @moduledoc """
  Typed startup reads for swap recovery and crashed-session restoration.

  Immutable swap/session options, enablement flags, and the startup workspace
  identity are captured before scheduling. Normalized directories form the
  stable resource identity;
  latest-wins admits at most one worker for that identity and cancels an older
  startup read. Scan, load, and swap-recovery filesystem reads run under the
  generation-owned scheduler `Task.Supervisor`, never in the Editor process.

  Application rechecks the current session configuration and startup workspace
  identity before calling `MingaEditor.Handlers.SessionRestore` owner APIs. A
  changed configuration or user-opened workspace reclassifies the candidate
  stale, canceled outcomes are ignored, and no
  EditorState or Buffer mutation occurs in the worker. Ordinary missing/clean
  session data completes as `:none`; worker failures log a warning. Scheduler
  unavailability is also logged and leaves the Editor in its safe current
  state.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Session
  alias Minga.Session.Snapshot
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Session, as: SessionState
  alias MingaEditor.State.TabBar

  @type recovered_entry ::
          {Session.swap_entry(), {:ok, String.t(), String.t()} | {:error, term()}}
  @type result :: :none | {:restore, Snapshot.t()} | {:recover, [recovered_entry()]}

  @type startup_identity ::
          {shell_id :: atom(), workspace_id :: non_neg_integer() | nil,
           tab_id :: non_neg_integer() | nil, buffers :: [pid()], active_buffer :: pid() | nil}

  @enforce_keys [
    :swap_opts,
    :session_opts,
    :swap_enabled?,
    :session_enabled?,
    :startup_identity
  ]
  defstruct [:swap_opts, :session_opts, :swap_enabled?, :session_enabled?, :startup_identity]

  @type t :: %__MODULE__{
          swap_opts: keyword(),
          session_opts: keyword(),
          swap_enabled?: boolean(),
          session_enabled?: boolean(),
          startup_identity: startup_identity()
        }

  @doc "Builds a bounded latest-wins request for the configured recovery files."
  @spec request(EditorState.t(), keyword(), keyword(), boolean(), boolean()) :: Request.t()
  def request(%EditorState{} = state, swap_opts, session_opts, swap_enabled?, session_enabled?)
      when is_list(swap_opts) and is_list(session_opts) and is_boolean(swap_enabled?) and
             is_boolean(session_enabled?) do
    effect = %__MODULE__{
      swap_opts: swap_opts,
      session_opts: session_opts,
      swap_enabled?: swap_enabled?,
      session_enabled?: session_enabled?,
      startup_identity: startup_identity(state)
    }

    Request.new(effect, resource(effect), Policy.latest_wins())
  end

  @doc "Schedules recovery reads, warning and retaining safe state when admission fails."
  @spec schedule(EditorState.t(), keyword(), keyword(), boolean(), boolean()) :: EditorState.t()
  def schedule(
        %EditorState{effect_scheduler: nil} = state,
        _swap_opts,
        _session_opts,
        _swap_enabled?,
        _session_enabled?
      ) do
    Minga.Log.warning(:editor, "Session recovery scheduler unavailable")
    state
  end

  def schedule(state, swap_opts, session_opts, swap_enabled?, session_enabled?) do
    request = request(state, swap_opts, session_opts, swap_enabled?, session_enabled?)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} -> state
      {:error, reason} -> admission_failed(state, reason)
    end
  catch
    :exit, reason -> admission_failed(state, {:scheduler_unavailable, reason})
  end

  @impl true
  @spec run(t()) :: {:ok, result()} | {:error, term()}
  def run(%__MODULE__{} = effect) do
    case recoverable_entries(effect) do
      [] -> load_crashed_session(effect)
      entries -> {:ok, {:recover, recover_entries(entries)}}
    end
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{}, %__MODULE__{} = newer), do: newer

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        %EditorState{} = state,
        %Outcome{request: %{effect: %__MODULE__{} = effect}} = outcome
      ) do
    case current_request?(state, effect) do
      :current -> apply_current(state, outcome)
      {:stale, reason} -> {state, Outcome.stale(outcome, reason)}
    end
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {:completed, result}}), do: result != :none
  def render?(%Outcome{}), do: false

  @spec resource(t()) :: Request.resource()
  defp resource(effect) do
    swap_dir = effect.swap_opts |> Keyword.get(:swap_dir, :default) |> normalize_path()

    session_file =
      if effect.session_enabled? do
        effect.session_opts |> Session.session_file() |> Path.expand()
      else
        :disabled
      end

    {:session_recovery, swap_dir, session_file}
  end

  @spec normalize_path(term()) :: term()
  defp normalize_path(path) when is_binary(path), do: Path.expand(path)
  defp normalize_path(other), do: other

  @spec recoverable_entries(t()) :: [Session.swap_entry()]
  defp recoverable_entries(%__MODULE__{swap_enabled?: false}), do: []

  defp recoverable_entries(%__MODULE__{swap_opts: opts}),
    do: Session.scan_recoverable_swaps(opts)

  @spec recover_entries([Session.swap_entry()]) :: [recovered_entry()]
  defp recover_entries(entries) do
    Enum.map(entries, fn entry -> {entry, Session.recover_swap_file(entry.swap_path)} end)
  end

  @spec load_crashed_session(t()) :: {:ok, result()} | {:error, term()}
  defp load_crashed_session(%__MODULE__{session_enabled?: false}), do: {:ok, :none}

  defp load_crashed_session(%__MODULE__{session_opts: opts}) do
    case Session.load(opts) do
      {:ok, %Snapshot{clean_shutdown: true}} -> {:ok, :none}
      {:ok, %Snapshot{} = snapshot} -> {:ok, {:restore, snapshot}}
      {:error, _reason} -> {:ok, :none}
    end
  end

  @spec current_request?(EditorState.t(), t()) :: :current | {:stale, atom()}
  defp current_request?(state, effect) do
    if current_configuration?(state, effect) do
      current_startup_identity(state, effect)
    else
      {:stale, :session_configuration_changed}
    end
  end

  @spec current_configuration?(EditorState.t(), t()) :: boolean()
  defp current_configuration?(state, effect) do
    SessionState.swap_enabled?(state.session) == effect.swap_enabled? and
      SessionState.enabled?(state.session) == effect.session_enabled? and
      SessionState.swap_opts(state.session) == effect.swap_opts and
      SessionState.session_opts(state.session) == effect.session_opts
  end

  @spec current_startup_identity(EditorState.t(), t()) :: :current | {:stale, atom()}
  defp current_startup_identity(state, effect) do
    if startup_identity(state) == effect.startup_identity,
      do: :current,
      else: {:stale, :workspace_changed}
  end

  @spec startup_identity(EditorState.t()) :: startup_identity()
  defp startup_identity(state) do
    tab_bar = state.shell_runtime.state.tab_bar

    workspace_id =
      if match?(%TabBar{}, tab_bar), do: TabBar.active_workspace_id(tab_bar), else: nil

    tab_id = if match?(%TabBar{}, tab_bar), do: tab_bar.active_id, else: nil

    {
      Runtime.id(state.shell_runtime),
      workspace_id,
      tab_id,
      state.workspace.buffers.list,
      state.workspace.buffers.active
    }
  end

  @spec apply_current(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  defp apply_current(state, %Outcome{value: {:completed, :none}} = outcome),
    do: {state, outcome}

  defp apply_current(state, %Outcome{value: {:completed, {:restore, snapshot}}} = outcome) do
    {SessionRestore.apply_session_snapshot(state, snapshot), outcome}
  end

  defp apply_current(state, %Outcome{value: {:completed, {:recover, entries}}} = outcome) do
    {SessionRestore.apply_recovered_entries(state, entries), outcome}
  end

  defp apply_current(state, %Outcome{value: {:failed, reason}} = outcome) do
    Minga.Log.warning(:editor, "Session recovery failed: #{inspect(reason)}")
    {state, outcome}
  end

  defp apply_current(state, %Outcome{} = outcome), do: {state, outcome}

  @spec admission_failed(EditorState.t(), term()) :: EditorState.t()
  defp admission_failed(state, reason) do
    Minga.Log.warning(:editor, "Session recovery not scheduled: #{inspect(reason)}")
    state
  end
end
