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
  alias MingaEditor.Handlers.SessionHandler
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Session, as: SessionState
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.State.TabBar

  @type recovered_entry :: SessionRestore.recovered_entry()
  @type resume :: SessionRestore.resume()
  @type result :: :none | {:resume, resume()}

  @typedoc """
  Which swap files this start recovers.

  An editor that opened a project recovers that project's files. An editor started on files recovers those files. Text of any other project stays on disk until that project is opened.
  """
  @type swap_scope :: {:project, String.t()} | :startup_buffers | :none

  @type startup_identity ::
          {shell_id :: atom(), workspace_id :: non_neg_integer() | nil,
           tab_id :: non_neg_integer() | nil, buffers :: [pid()], active_buffer :: pid() | nil}

  @enforce_keys [
    :swap_opts,
    :session_opts,
    :swap_enabled?,
    :session_enabled?,
    :swap_scope,
    :startup_identity
  ]
  defstruct [
    :swap_opts,
    :session_opts,
    :swap_enabled?,
    :session_enabled?,
    :swap_scope,
    :startup_identity
  ]

  @type t :: %__MODULE__{
          swap_opts: keyword(),
          session_opts: keyword(),
          swap_enabled?: boolean(),
          session_enabled?: boolean(),
          swap_scope: swap_scope(),
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
      swap_scope: swap_scope(state),
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
    scope = scan_scope(effect)

    resume = %{
      snapshot: load_project_session(effect),
      recovered: effect |> recoverable_entries(scope) |> read_entries(),
      waiting_elsewhere: waiting_elsewhere(effect, scope)
    }

    case resume do
      %{snapshot: nil, recovered: [], waiting_elsewhere: 0} -> {:ok, :none}
      resume -> {:ok, {:resume, resume}}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        %EditorState{} = state,
        %Outcome{request: %{effect: %__MODULE__{} = effect}} = outcome
      ) do
    case current_request?(state, effect) do
      :current -> apply_current(state, outcome)
      {:session_stale, reason} -> apply_unsaved_text(state, outcome, reason)
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

    {:session_recovery, swap_dir, session_file, effect.swap_scope}
  end

  @spec normalize_path(term()) :: term()
  defp normalize_path(path) when is_binary(path), do: Path.expand(path)
  defp normalize_path(other), do: other

  # The swap files this editor recovers, as a scan scope. `nil` recovers none.
  @spec scan_scope(t()) :: Session.Swap.Recovery.scope() | nil
  defp scan_scope(%__MODULE__{swap_scope: {:project, root}}), do: {:project, root}
  defp scan_scope(%__MODULE__{swap_scope: :none}), do: nil

  defp scan_scope(%__MODULE__{swap_scope: :startup_buffers, startup_identity: identity}) do
    {_shell, _workspace, _tab, buffers, _active} = identity
    {:files, Enum.flat_map(buffers, &buffer_file/1)}
  end

  # Runs in the recovery worker, so the buffer call does not block the Editor.
  @spec buffer_file(term()) :: [String.t()]
  defp buffer_file(buffer) when is_pid(buffer) do
    case Minga.Buffer.file_path(buffer) do
      path when is_binary(path) -> [path]
      nil -> []
    end
  catch
    :exit, _reason -> []
  end

  defp buffer_file(_not_a_buffer), do: []

  @spec recoverable_entries(t(), Session.Swap.Recovery.scope() | nil) :: [Session.swap_entry()]
  defp recoverable_entries(%__MODULE__{swap_enabled?: false}, _scope), do: []
  defp recoverable_entries(%__MODULE__{}, nil), do: []

  defp recoverable_entries(%__MODULE__{swap_opts: opts}, scope),
    do: Session.scan_recoverable_swaps(Keyword.put(opts, :scope, scope))

  # Reading leaves each swap on disk. A swap is removed when a buffer has taken its text over.
  @spec read_entries([Session.swap_entry()]) :: [recovered_entry()]
  defp read_entries(entries) do
    Enum.map(entries, fn entry -> {entry, Session.read_swap_file(entry.swap_path)} end)
  end

  # The number of other places (projects, or loose files as one place) with unsaved text waiting.
  @spec waiting_elsewhere(t(), Session.Swap.Recovery.scope() | nil) :: non_neg_integer()
  defp waiting_elsewhere(%__MODULE__{swap_enabled?: false}, _scope), do: 0

  defp waiting_elsewhere(%__MODULE__{swap_opts: opts}, nil),
    do: opts |> Session.recoverable_projects() |> length()

  defp waiting_elsewhere(%__MODULE__{swap_opts: opts}, scope),
    do: opts |> Keyword.put(:outside, scope) |> Session.recoverable_projects() |> length()

  # Opening a project picks up where you left off, after a clean quit as well as after a crash.
  # A saved session with no files leaves the project home in place.
  @spec load_project_session(t()) :: Snapshot.t() | nil
  defp load_project_session(%__MODULE__{session_enabled?: false}), do: nil

  defp load_project_session(%__MODULE__{session_opts: opts}) do
    case Session.load(opts) do
      {:ok, %Snapshot{buffers: [_ | _]} = snapshot} -> snapshot
      {:ok, %Snapshot{}} -> nil
      {:error, _reason} -> nil
    end
  end

  # `:session_stale` means the saved session no longer applies but the swap scan still does.
  # A file the user opened meanwhile wins over the saved session, while unsaved text is still recovered.
  @spec current_request?(EditorState.t(), t()) ::
          :current | {:session_stale, atom()} | {:stale, atom()}
  defp current_request?(state, effect) do
    cond do
      not current_swap_configuration?(state, effect) ->
        {:stale, :session_configuration_changed}

      not current_session_configuration?(state, effect) ->
        {:session_stale, :session_configuration_changed}

      startup_identity(state) != effect.startup_identity ->
        {:session_stale, :workspace_changed}

      true ->
        :current
    end
  end

  @spec current_swap_configuration?(EditorState.t(), t()) :: boolean()
  defp current_swap_configuration?(state, effect) do
    SessionHandler.swap_recovery_enabled?(state) == effect.swap_enabled? and
      SessionState.swap_opts(state.session) == effect.swap_opts and
      current_swap_scope?(swap_scope(state), effect.swap_scope)
  end

  @spec current_session_configuration?(EditorState.t(), t()) :: boolean()
  defp current_session_configuration?(state, effect) do
    SessionHandler.restore_enabled?(state) == effect.session_enabled? and
      SessionHandler.project_session_opts(state) == effect.session_opts
  end

  # An editor that began with nothing open (`:none`) or on files keeps that scope when files are opened later.
  # Only the project changing makes the result belong to another place.
  @spec current_swap_scope?(swap_scope(), swap_scope()) :: boolean()
  defp current_swap_scope?({:project, root}, {:project, root}), do: true
  defp current_swap_scope?({:project, _now}, _then), do: false
  defp current_swap_scope?(_now, {:project, _then}), do: false
  defp current_swap_scope?(_now, _then), do: true

  @spec swap_scope(EditorState.t()) :: swap_scope()
  defp swap_scope(state) do
    root = WorkspaceState.project_root(state.workspace)

    cond do
      SessionState.project_session?(state.session) and is_binary(root) -> {:project, root}
      state.workspace.buffers.list != [] -> :startup_buffers
      true -> :none
    end
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

  defp apply_current(state, %Outcome{value: {:completed, {:resume, resume}}} = outcome),
    do: {SessionRestore.resume(state, resume), outcome}

  defp apply_current(state, %Outcome{value: {:failed, reason}} = outcome) do
    Minga.Log.warning(:editor, "Session recovery failed: #{inspect(reason)}")
    {state, outcome}
  end

  defp apply_current(state, %Outcome{} = outcome), do: {state, outcome}

  @spec apply_unsaved_text(EditorState.t(), Outcome.t(), atom()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_unsaved_text(
         state,
         %Outcome{value: {:completed, {:resume, %{recovered: [_ | _]} = resume}}} = outcome,
         _reason
       ),
       do: {SessionRestore.resume(state, %{resume | snapshot: nil}), outcome}

  defp apply_unsaved_text(state, outcome, reason), do: {state, Outcome.stale(outcome, reason)}

  @spec admission_failed(EditorState.t(), term()) :: EditorState.t()
  defp admission_failed(state, reason) do
    Minga.Log.warning(:editor, "Session recovery not scheduled: #{inspect(reason)}")
    state
  end
end
