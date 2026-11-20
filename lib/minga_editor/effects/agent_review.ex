defmodule MingaEditor.Effects.AgentReview do
  @moduledoc "Acquires a cumulative file review without blocking or retargeting the Editor."

  @behaviour MingaEditor.Effect

  alias MingaAgent.ProjectView
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.FocusOwner
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.Window
  alias MingaEditor.WindowFocus

  @typep source :: {:project_view, ProjectView.t(), String.t()} | {:file, String.t()}

  @enforce_keys [
    :workspace_id,
    :session,
    :tab_id,
    :review_tab_id,
    :window_id,
    :window_generation,
    :window_content,
    :focus_context,
    :preview_revision,
    :generation,
    :path,
    :source,
    :hunks,
    :postimage_digest
  ]
  defstruct [{:resolution, nil} | @enforce_keys]

  @type t :: %__MODULE__{
          workspace_id: non_neg_integer(),
          session: pid() | nil,
          tab_id: Tab.id(),
          review_tab_id: Tab.id(),
          window_id: Window.id(),
          window_generation: pos_integer(),
          window_content: MingaEditor.Window.Content.t(),
          focus_context: {Minga.RenderModel.UI.FocusOwner.t(), atom(), boolean()},
          preview_revision: non_neg_integer(),
          generation: non_neg_integer(),
          path: String.t(),
          source: source(),
          hunks: [Minga.Core.Diff.hunk()],
          postimage_digest: EditTimeline.postimage_digest() | nil,
          resolution: {Minga.Buffer.Fork.review_revision(), [DiffReview.resolution()]} | nil
        }

  @doc "Schedules the offered file in the current workspace without changing selection or focus."
  @spec schedule(EditorState.t(), String.t()) :: EditorState.t()
  def schedule(%EditorState{effect_scheduler: nil} = state, _path) do
    NoticeWorkflow.publish(state, "Review is unavailable while the editor is reconnecting")
  end

  def schedule(%EditorState{} = state, path) when is_binary(path) do
    with {:ok, effect} <- capture(state, path),
         {:ok, _id, _phase} <- EffectScheduler.schedule(state.effect_scheduler, request(effect)) do
      NoticeWorkflow.publish(state, "Loading review: #{path}")
    else
      {:error, :no_changes} ->
        NoticeWorkflow.publish(state, "No changes to review: #{path}")

      {:error, reason} ->
        NoticeWorkflow.publish(state, "Could not review #{path}: #{inspect(reason)}")
    end
  catch
    :exit, reason ->
      NoticeWorkflow.publish(state, "Could not load review #{path}: #{inspect(reason)}")
  end

  @doc "Schedules publication of the exact conflict choices from the current review."
  @spec resolve_fork(EditorState.t(), String.t(), Minga.Buffer.Fork.review_revision(), [
          DiffReview.resolution()
        ]) :: EditorState.t()
  def resolve_fork(%EditorState{effect_scheduler: nil} = state, path, _revision, _decisions) do
    NoticeWorkflow.publish(state, "Could not apply conflict choices: #{path}")
  end

  def resolve_fork(%EditorState{effect_scheduler: scheduler} = state, path, revision, decisions) do
    with {:ok, effect} <- capture(state, path),
         {:ok, _id, _phase} <-
           EffectScheduler.schedule(
             scheduler,
             Request.new(
               %{effect | resolution: {revision, decisions}},
               {:agent_fork_resolution, effect.workspace_id},
               Policy.fifo(0),
               activity: :agent_review_loading
             )
           ) do
      NoticeWorkflow.publish(state, "Applying conflict choices: #{path}")
    else
      _ -> NoticeWorkflow.publish(state, "Could not apply conflict choices: #{path}")
    end
  catch
    :exit, _ -> NoticeWorkflow.publish(state, "Could not apply conflict choices: #{path}")
  end

  @doc "Builds a latest-wins request bound to the captured workspace and presentation."
  @spec request(t()) :: Request.t()
  def request(%__MODULE__{} = effect) do
    Request.new(effect, {:agent_review, effect.workspace_id}, Policy.latest_wins(),
      timeout_ms: 10_000,
      activity: :agent_review_loading
    )
  end

  @impl true
  @spec run(t()) :: {:ok, DiffReview.t() | :no_changes | :fork_resolved} | {:error, term()}
  def run(%__MODULE__{resolution: {revision, decisions}, source: {:project_view, view, path}}) do
    case ProjectView.Overlay.resolve_fork_conflicts(view, path, revision, decisions) do
      :ok -> {:ok, :fork_resolved}
      {_failure, reason} -> {:error, reason}
    end
  end

  def run(%__MODULE__{resolution: {_, _}}), do: {:error, :fork_unavailable}

  def run(%__MODULE__{source: {:project_view, view, path}} = effect) do
    case ProjectView.Overlay.fork_conflict_snapshot(view, path) do
      {:ok, revision, regions} ->
        case DiffReview.from_fork_snapshot(effect.path, revision, regions) do
          nil -> run_cumulative(effect)
          review -> {:ok, review}
        end

      {:error, _} ->
        run_cumulative(effect)
    end
  end

  def run(%__MODULE__{} = effect), do: run_cumulative(effect)

  @spec run_cumulative(t()) :: {:ok, DiffReview.t() | :no_changes} | {:error, term()}
  defp run_cumulative(%__MODULE__{hunks: []}), do: {:ok, :no_changes}

  defp run_cumulative(%__MODULE__{
         path: path,
         source: source,
         hunks: hunks,
         postimage_digest: digest
       }) do
    with {:ok, content} <- read_source(source),
         true <- :crypto.hash(:sha256, content) == digest do
      case DiffReview.from_hunks(path, content, hunks) do
        nil -> {:ok, :no_changes}
        %DiffReview{} = review -> {:ok, review}
      end
    else
      false -> {:error, :review_source_changed}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{request: %Request{effect: %__MODULE__{} = effect}, value: {:completed, result}} =
          outcome
      ) do
    if completion_current?(state, effect) do
      case install_result(state, effect, result) do
        {:ok, updated} ->
          {updated, outcome}

        {:error, reason} ->
          {NoticeWorkflow.publish(state, failure_message(effect.path, reason)),
           Outcome.failed(outcome.request, reason)}
      end
    else
      {state, Outcome.stale(outcome, :review_context_changed)}
    end
  end

  def apply(
        state,
        %Outcome{request: %Request{effect: %__MODULE__{} = effect}, value: {:failed, reason}} =
          outcome
      ) do
    if completion_current?(state, effect) do
      state = freeze_stale_fork_review(state, effect, reason)
      {NoticeWorkflow.publish(state, failure_message(effect.path, reason)), outcome}
    else
      {state, Outcome.stale(outcome, :review_context_changed)}
    end
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {:completed, _result}}), do: true
  def render?(%Outcome{value: {:failed, _reason}}), do: true
  def render?(%Outcome{}), do: false

  @spec capture(EditorState.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  defp capture(state, path) do
    tab_bar = Runtime.state(state.shell_runtime).tab_bar
    timeline = state.workspace.agent_ui.view.edit_timeline
    hunks = EditTimeline.cumulative_hunks(timeline, path)

    with %TabBar{} <- tab_bar,
         %Workspace{payload: %WorkspaceAgent{} = payload} = workspace <-
           TabBar.active_workspace(tab_bar),
         %Tab{id: tab_id} <- TabBar.active(tab_bar),
         %Window{} = window <- Windows.active_struct(state.workspace.windows),
         %Tab{id: review_tab_id} <- find_review_tab(tab_bar, workspace.id),
         digest = EditTimeline.postimage_digest(timeline, path),
         {:ok, source} <- capture_source(payload.project_view, workspace.project_root, path) do
      {:ok,
       %__MODULE__{
         workspace_id: workspace.id,
         session: payload.session,
         tab_id: tab_id,
         review_tab_id: review_tab_id,
         window_id: window.id,
         window_generation: window.accessibility_generation,
         window_content: window.content,
         focus_context:
           {FocusOwner.derive(state), state.workspace.agent_ui.view.presentation.focus,
            state.workspace.agent_ui.panel.input_focused},
         preview_revision: state.workspace.agent_ui.view.preview.content_revision,
         generation: timeline.generation,
         path: path,
         source: source,
         hunks: hunks,
         postimage_digest: digest
       }}
    else
      [] -> {:error, :no_changes}
      {:error, _reason} = error -> error
      _unavailable -> {:error, :review_workspace_unavailable}
    end
  end

  @spec find_review_tab(TabBar.t(), non_neg_integer()) :: Tab.t() | nil
  defp find_review_tab(tab_bar, workspace_id) do
    case TabBar.active(tab_bar) do
      %Tab{kind: :agent, group_id: ^workspace_id} = tab ->
        tab

      _other ->
        tab_bar |> TabBar.tabs_in_workspace(workspace_id) |> Enum.find(&(&1.kind == :agent))
    end
  end

  @spec capture_source(ProjectView.t() | nil, String.t() | nil, String.t()) ::
          {:ok, source()} | {:error, term()}
  defp capture_source(%ProjectView{} = view, _root, path) do
    relative =
      Path.relative_to(Path.expand(path, view.project_root), Path.expand(view.project_root))

    case ProjectView.normalize_relative_path(relative) do
      {:ok, normalized} -> {:ok, {:project_view, view, normalized}}
      {:error, _reason} -> {:error, :file_outside_project_view}
    end
  end

  defp capture_source(nil, root, path) when is_binary(root),
    do: {:ok, {:file, Path.expand(path, root)}}

  defp capture_source(nil, nil, path) do
    case Path.type(path) do
      :absolute -> {:ok, {:file, path}}
      _relative -> {:error, :project_root_unavailable}
    end
  end

  @spec read_source(source()) :: {:ok, binary()} | {:error, term()}
  defp read_source({:project_view, view, path}), do: ProjectView.read_file(view, path)
  defp read_source({:file, path}), do: File.read(path)

  @spec current?(EditorState.t(), t()) :: boolean()
  defp current?(state, effect) do
    case capture(state, effect.path) do
      {:ok, current} -> current == %{effect | resolution: nil}
      {:error, _reason} -> false
    end
  end

  @spec completion_current?(EditorState.t(), t()) :: boolean()
  defp completion_current?(state, %{resolution: {revision, _}} = effect) do
    tab_bar = Runtime.state(state.shell_runtime).tab_bar
    preview = state.workspace.agent_ui.view.preview

    with %TabBar{} <- tab_bar,
         %Workspace{id: id, payload: %WorkspaceAgent{session: session}} <-
           TabBar.active_workspace(tab_bar),
         %DiffReview{path: path, fork_revision: ^revision} <- Preview.diff_review(preview) do
      {id, session, path, preview.content_revision} ==
        {effect.workspace_id, effect.session, effect.path, effect.preview_revision}
    else
      _ -> false
    end
  end

  defp completion_current?(state, effect), do: current?(state, effect)

  @spec freeze_stale_fork_review(EditorState.t(), t(), term()) :: EditorState.t()
  defp freeze_stale_fork_review(state, %{resolution: {_, _}, path: path}, reason)
       when reason in [:stale_parent, :stale_fork] do
    ui = state.workspace.agent_ui
    preview = Preview.refresh_after_write(ui.view.preview, path)
    Workflow.install_agent_ui(state, UIState.replace_preview(ui, preview))
  end

  defp freeze_stale_fork_review(state, _effect, _reason), do: state

  @spec failure_message(String.t(), term()) :: String.t()
  defp failure_message(path, :review_source_changed),
    do: "File changed before review could load: #{path}. Review again."

  defp failure_message(path, :review_pane_unavailable),
    do: "Could not review #{path}: the Agent pane is unavailable. Reopen the Agent workspace."

  defp failure_message(path, reason) when reason in [:stale_parent, :stale_fork],
    do: "Conflict choices were not applied: #{path} changed. Open Review again."

  defp failure_message(path, :publication_baseline_conflict),
    do: "Conflict choices were not applied: the staging baseline for #{path} changed."

  defp failure_message(path, reason), do: "Could not review #{path}: #{inspect(reason)}"

  @spec install_result(EditorState.t(), t(), DiffReview.t() | :no_changes | :fork_resolved) ::
          {:ok, EditorState.t()} | {:error, term()}
  defp install_result(state, effect, :no_changes) do
    {:ok, NoticeWorkflow.publish(state, "No changes to review: #{effect.path}")}
  end

  defp install_result(state, effect, :fork_resolved) do
    ui = state.workspace.agent_ui
    preview = Preview.clear(ui.view.preview)
    ui = UIState.replace_preview(ui, preview)
    ui = leave_resolved_review(ui, ui.view.presentation.focus)
    state = Workflow.install_agent_ui(state, ui)
    {:ok, NoticeWorkflow.publish(state, "Resolved fork conflicts: #{effect.path}")}
  end

  defp install_result(state, effect, %DiffReview{} = review) do
    revealed = AgentCommands.reveal_agent_view(state, effect.review_tab_id)

    with {window_id, _window} <- SessionState.find_agent_window(revealed.workspace),
         {:ok, focused} <- WindowFocus.focus_result(revealed, window_id) do
      focused = %{focused | workspace: SessionState.set_keymap_scope(focused.workspace, :agent)}
      ui = focused.workspace.agent_ui
      preview = Preview.set_diff(ui.view.preview, review)
      ui = ui |> UIState.replace_preview(preview) |> UIState.set_focus(:file_viewer)
      focused = Workflow.install_agent_ui(focused, ui)
      label = if review.fork_revision, do: "Resolve fork conflicts", else: "Read-only review"
      {:ok, NoticeWorkflow.publish(focused, "#{label}: #{effect.path}")}
    else
      nil -> {:error, :review_pane_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @spec leave_resolved_review(UIState.t(), atom()) :: UIState.t()
  defp leave_resolved_review(ui, :file_viewer), do: UIState.set_focus(ui, :chat)
  defp leave_resolved_review(ui, _focus), do: ui
end
