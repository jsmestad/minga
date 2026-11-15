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
  defstruct @enforce_keys

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
          postimage_digest: EditTimeline.postimage_digest()
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

  @doc "Builds a latest-wins request bound to the captured workspace and presentation."
  @spec request(t()) :: Request.t()
  def request(%__MODULE__{} = effect) do
    Request.new(effect, {:agent_review, effect.workspace_id}, Policy.latest_wins(),
      timeout_ms: 10_000,
      activity: :agent_review_loading
    )
  end

  @impl true
  @spec run(t()) :: {:ok, DiffReview.t() | :no_changes} | {:error, term()}
  def run(%__MODULE__{path: path, source: source, hunks: hunks, postimage_digest: digest}) do
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
    if current?(state, effect) do
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
    if current?(state, effect) do
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
         [_ | _] <- hunks,
         digest when is_binary(digest) <- EditTimeline.postimage_digest(timeline, path),
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
      {:ok, current} -> current == effect
      {:error, _reason} -> false
    end
  end

  @spec failure_message(String.t(), term()) :: String.t()
  defp failure_message(path, :review_source_changed),
    do: "File changed before review could load: #{path}. Review again."

  defp failure_message(path, :review_pane_unavailable),
    do: "Could not review #{path}: the Agent pane is unavailable. Reopen the Agent workspace."

  defp failure_message(path, reason), do: "Could not review #{path}: #{inspect(reason)}"

  @spec install_result(EditorState.t(), t(), DiffReview.t() | :no_changes) ::
          {:ok, EditorState.t()} | {:error, term()}
  defp install_result(state, effect, :no_changes) do
    {:ok, NoticeWorkflow.publish(state, "No changes to review: #{effect.path}")}
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
      {:ok, NoticeWorkflow.publish(focused, "Read-only review: #{effect.path}")}
    else
      nil -> {:error, :review_pane_unavailable}
      {:error, _reason} = error -> error
    end
  end
end
