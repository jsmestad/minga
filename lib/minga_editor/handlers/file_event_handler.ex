defmodule MingaEditor.Handlers.FileEventHandler do
  @moduledoc """
  Owns file, file-tree, save follow-up, and Git boundary actions.

  `dispatch/2` performs state transitions first and interprets focused actions
  in list order. File-tree refresh keeps its typed `Effect.Request` scheduler
  contract, stable root identity, bounded coalescing, supervised workers, and
  terminal outcomes. Save follow-ups run in the Editor process: LSP requests
  are issued before deferred session persistence and rendering.

  File-tree or LSP failures retain their existing domain reporting policy.
  """

  alias MingaEditor.Extension.EventWorkflow
  alias MingaEditor.Extension.GitDiff
  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.GuiSearchWorkflow
  alias MingaEditor.LspActions
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.LSP, as: LSPState

  @typedoc "Effects that the file event handler may return."
  @type file_effect ::
          {:render, pos_integer()}
          | {:request_code_lens}
          | {:request_inlay_hints}
          | {:save_session_deferred}

  @doc "Applies one file/Git event and its focused actions."
  @spec dispatch(EditorState.t(), term()) :: EditorState.t()
  def dispatch(%EditorState{} = state, message) do
    {state, effects} = handle(state, message)
    apply_effects(state, effects)
  end

  @doc """
  Dispatches a file/git event to the appropriate handler.

  Returns `{state, effects}` where effects encode all side-effectful
  operations.
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [file_effect()]}

  def handle(state, {:minga_event, :git_status_changed, event}) do
    handle_git_status_changed(state, event)
  end

  def handle(state, {:minga_event, :buffer_saved, %Minga.Events.BufferEvent{buffer: buf}}) do
    handle_buffer_saved(state, buf)
  end

  def handle(state, {:minga_event, :buffer_changed, %Minga.Events.BufferChangedEvent{} = event}) do
    handle_buffer_changed(state, event)
  end

  def handle(
        state,
        {:minga_event, :diagnostics_updated, %Minga.Events.DiagnosticsUpdatedEvent{uri: uri}}
      ) do
    handle_diagnostics_updated(state, uri)
  end

  def handle(state, {:minga_event, :file_written, %Minga.Events.FileWrittenEvent{path: path}}) do
    handle_file_changed(state, path)
  end

  def handle(
        state,
        {:minga_event, :project_rebuilt, %Minga.Events.ProjectRebuiltEvent{root: root}}
      ) do
    handle_project_rebuilt(state, root)
  end

  def handle(
        state,
        {:minga_event, :project_rebuild_failed,
         %Minga.Events.ProjectRebuildFailedEvent{root: root}}
      ) do
    handle_project_rebuild_failed(state, root)
  end

  def handle(state, {:file_changed_on_disk, path}) when is_binary(path) do
    handle_file_changed(state, path)
  end

  def handle(state, _msg) do
    {state, []}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec apply_effects(EditorState.t(), [file_effect()]) :: EditorState.t()
  defp apply_effects(state, []), do: state

  defp apply_effects(state, [effect | rest]) do
    state = apply_effect(state, effect)
    apply_effects(state, rest)
  end

  @spec apply_effect(EditorState.t(), file_effect()) :: EditorState.t()
  defp apply_effect(state, {:render, delay_ms}),
    do: MingaEditor.schedule_render(state, delay_ms)

  defp apply_effect(state, {:request_code_lens}), do: LspActions.code_lens(state)
  defp apply_effect(state, {:request_inlay_hints}), do: LspActions.inlay_hints(state)

  defp apply_effect(state, {:save_session_deferred}) do
    if state.frontend.backend != :headless, do: send(self(), :save_session)
    state
  end

  # The project home's header shows the branch and change count; it learns them when the repository reports in.
  @spec refresh_home_git(EditorState.t(), Minga.Events.GitStatusEvent.t()) :: EditorState.t()
  defp refresh_home_git(
         %{workspace: %{launchpad: %MingaEditor.State.Launchpad{} = home}} = state,
         event
       ) do
    home = MingaEditor.State.Launchpad.accept_git(home, event)
    %{state | workspace: MingaEditor.Session.State.set_launchpad(state.workspace, home)}
  end

  defp refresh_home_git(state, _event), do: state

  @spec handle_git_status_changed(EditorState.t(), Minga.Events.GitStatusEvent.t()) ::
          {EditorState.t(), [file_effect()]}
  defp handle_git_status_changed(
         state,
         %Minga.Events.GitStatusEvent{git_root: git_root, entries: entries} = event
       ) do
    state = state |> FileTreeFreshness.refresh_git_status(event) |> refresh_home_git(event)

    case SidebarWorkflow.git_status_panel(state) do
      %GitStatusPanel{git_root: ^git_root} = panel ->
        state =
          state
          |> SidebarWorkflow.refresh_git_status(GitStatusPanel.refresh(panel, event))
          |> Workflow.ensure_available()

        {runtime, workspace} =
          Runtime.route_event(
            state.shell_runtime,
            state.workspace,
            {:git_status_changed, entries}
          )

        new_state = %{state | shell_runtime: runtime, workspace: workspace}
        {new_state, [{:render, 16}]}

      _other_panel ->
        if FileTreeFreshness.open?(state) or MingaEditor.Input.EmptyState.showing_home?(state),
          do: {state, [{:render, 16}]},
          else: {state, []}
    end
  end

  @spec handle_buffer_saved(EditorState.t(), pid()) :: {EditorState.t(), [file_effect()]}
  defp handle_buffer_saved(state, saved_buf) do
    saved_path = Minga.Buffer.file_path(saved_buf)

    new_state =
      state
      |> FileTreeFreshness.refresh_git_status_from_cache()
      |> MingaEditor.BufferFileIdentity.rebind(saved_buf, saved_path)
      |> GitDiff.refresh_saved(saved_buf)
      |> dispatch_extension_buffer_saved(saved_buf)

    effects = [
      {:request_code_lens},
      {:request_inlay_hints},
      {:render, 16}
    ]

    effects =
      if state.frontend.backend != :headless do
        Enum.concat(effects, [{:save_session_deferred}])
      else
        effects
      end

    {new_state, effects}
  end

  @spec dispatch_extension_buffer_saved(EditorState.t(), pid()) :: EditorState.t()
  defp dispatch_extension_buffer_saved(state, saved_buf) do
    EventWorkflow.dispatch(state, {:buffer_saved, saved_buf})
  end

  @spec handle_buffer_changed(EditorState.t(), Minga.Events.BufferChangedEvent.t()) ::
          {EditorState.t(), [file_effect()]}
  defp handle_buffer_changed(state, %Minga.Events.BufferChangedEvent{buffer: buffer} = event) do
    state = GuiSearchWorkflow.buffer_changed(state, event)
    state = MingaEditor.Agent.DraftWorkflow.edited(state, buffer)
    state = %{state | lsp: LSPState.clear_semantic_tokens(state.lsp, buffer)}

    if redraw_shown_buffer?(state, event) or FileTreeFreshness.buffer_under_tree?(state, buffer) do
      {state, [{:render, 16}]}
    else
      {state, []}
    end
  end

  # The command that makes a user's edit draws it. Any other writer (command output, an agent,
  # a language server) has no command, so the window that shows the buffer needs a frame.
  @spec redraw_shown_buffer?(EditorState.t(), Minga.Events.BufferChangedEvent.t()) :: boolean()
  defp redraw_shown_buffer?(_state, %Minga.Events.BufferChangedEvent{source: :user}), do: false

  defp redraw_shown_buffer?(state, %Minga.Events.BufferChangedEvent{buffer: buffer}) do
    MingaEditor.State.Windows.find_by_buffer(state.workspace.windows, buffer) != nil
  end

  @spec handle_diagnostics_updated(EditorState.t(), String.t()) ::
          {EditorState.t(), [file_effect()]}
  defp handle_diagnostics_updated(state, uri) do
    if FileTreeFreshness.diagnostic_uri_under_tree?(state, uri) do
      {state, [{:render, 16}]}
    else
      {state, []}
    end
  end

  @spec handle_file_changed(EditorState.t(), String.t()) :: {EditorState.t(), [file_effect()]}
  defp handle_file_changed(state, path) do
    if FileTreeFreshness.path_under_tree?(state, path) do
      {FileTreeFreshness.request_refresh(state, 50), []}
    else
      {state, []}
    end
  end

  @spec handle_project_rebuilt(EditorState.t(), String.t()) :: {EditorState.t(), [file_effect()]}
  defp handle_project_rebuilt(state, root) do
    state =
      state
      |> FileTreeFreshness.update_project_root(root)
      |> maybe_refresh_file_picker(root)

    {state, [{:render, 16}]}
  end

  # A failed rebuild publishes no new files, so the file tree keeps its current content.
  # An open file picker refetches so it leaves its loading state and shows the failure.
  @spec handle_project_rebuild_failed(EditorState.t(), String.t() | nil) ::
          {EditorState.t(), [file_effect()]}
  defp handle_project_rebuild_failed(state, root) do
    {maybe_refresh_file_picker(state, root), [{:render, 16}]}
  end

  @spec maybe_refresh_file_picker(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp maybe_refresh_file_picker(
         %{
           shell_runtime: %{
             state: %{
               modal: {:picker, %{picker_ui: %{source: MingaEditor.UI.Picker.FileSource}}}
             }
           }
         } = state,
         _root
       ) do
    PickerUI.refresh_items(state)
  end

  defp maybe_refresh_file_picker(
         %{
           shell_runtime: %{
             state: %{
               modal:
                 {:picker,
                  %{
                    picker_ui: %{
                      source: MingaEditor.UI.Picker.FileAttachmentSource,
                      context: context
                    }
                  }}
             }
           }
         } = state,
         root
       ) do
    if MingaEditor.UI.Picker.FileAttachmentSource.refresh_inventory?(context, root),
      do: PickerUI.refresh_items(state),
      else: state
  end

  defp maybe_refresh_file_picker(state, _root), do: state
end
