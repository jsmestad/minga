defmodule MingaEditor.FocusOwner do
  @moduledoc "Derives keyboard ownership once at the editor-to-frame boundary."

  alias Minga.RenderModel.UI.FocusOwner
  alias MingaEditor.Input.InlineAsk
  alias MingaEditor.Input.InlineEdit
  alias MingaEditor.Input.InlineOverlay
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Drawers
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Search

  @spec derive(EditorState.t()) :: FocusOwner.t()
  def derive(%EditorState{} = state) do
    shell_state = Runtime.state(state.shell_runtime)
    modal = modal(shell_state)
    {responder, surface, generation} = overlay_owner(ModalOverlay.tag(modal), modal, state)

    %FocusOwner{
      responder: responder,
      surface: surface,
      window_id: state.workspace.windows.active,
      generation: generation
    }
  end

  defp modal(%ShellState{modal: modal}), do: modal
  defp modal(_shell_state), do: :none

  # Conflict precedes both inline overlays in Input.overlay_handlers/0.
  defp overlay_owner(:conflict, _modal, _state), do: {:editor_view, :conflict, 0}

  defp overlay_owner(tag, modal, state) do
    inline_owner(active_inline(state), tag, modal, state)
  end

  defp active_inline(%{shell_runtime: %{state: %ShellState{}}} = state) do
    {InlineOverlay.active(state, InlineEdit.spec()),
     InlineOverlay.active(state, InlineAsk.spec([]))}
  end

  defp active_inline(_state), do: {nil, nil}

  defp inline_owner({%MingaEditor.State.InlineEdit{}, _ask}, _tag, _modal, _state),
    do: {:inline_edit, :inline_edit, 0}

  defp inline_owner({nil, %MingaEditor.State.InlineAsk{}}, _tag, _modal, _state),
    do: {:editor_view, :inline_ask, 0}

  defp inline_owner({nil, nil}, tag, modal, state), do: modal_owner(tag, modal, state)

  defp modal_owner(:prompt, _modal, _state), do: {:editor_view, :prompt, 0}

  # A picker with nothing to filter takes no text.
  # The editor view keeps the keyboard, so its list keys reach the picker.
  defp modal_owner(:picker, {:picker, %{picker_ui: picker}}, _state) do
    responder =
      if MingaEditor.State.Picker.list_keys?(picker), do: :editor_view, else: :picker_query

    {responder, :picker, picker.activation_offer.generation}
  end

  # Pending trigger bookkeeping also uses the completion tag, but does not
  # claim input until the completion value has arrived.
  defp modal_owner(
         :completion,
         {:completion, %{completion: %Minga.Editing.Completion{}}},
         %{workspace: %{editing: %{mode: :insert}}} = state
       ),
       do: {:editor_view, :completion, ModalWorkflow.completion_generation(state)}

  # Command completion is handled by the editing model's command-mode handler,
  # not by Input.Completion (which only claims insert-mode completions).
  defp modal_owner(:command_completion, {:command_completion, %{generation: generation}}, _state),
    do: {:editor_view, :command_completion, generation}

  defp modal_owner(_tag, _modal, state) do
    if Search.gui_search_active?(state.workspace.search) do
      {:search_query, :search, 0}
    else
      hover_owner(Runtime.state(state.shell_runtime), state)
    end
  end

  # Hover is an overlay handler above surface routing, but below the modals.
  defp hover_owner(%ShellState{hover_popup: %{focused: true}}, _state),
    do: {:editor_view, :hover_popup, 0}

  defp hover_owner(%ShellState{} = shell, state) do
    if Drawers.focused?(ShellState.drawers(shell), :tasks),
      do: drawer_owner(state),
      else: surface_owner(state)
  end

  defp hover_owner(_shell, state), do: surface_owner(state)

  # The tasks drawer runs ahead of the active window's scope and yields only the leader.
  defp drawer_owner(%{workspace: %{editing: %{mode: :normal}}} = state) do
    if Minga.Editing.in_leader?(state),
      do: {:editor_view, :editor, 0},
      else: {:editor_view, :tasks, 0}
  end

  defp drawer_owner(_state), do: {:editor_view, :tasks, 0}

  defp surface_owner(%{workspace: %{keymap_scope: :file_tree, file_tree: ft}} = state) do
    case MingaEditor.State.FileTree.editing(ft) do
      %{token: token} -> {:inline_edit, :inline_edit, token}
      nil -> normal_source_owner(state)
    end
  end

  defp surface_owner(state), do: normal_source_owner(state)

  # EmptyState and GitStatus yield leader input to ModeFSM; FileTree browse
  # delegates it there. Native editing/help/filter admission happens first.
  defp normal_source_owner(%{workspace: %{editing: %{mode: :normal}}} = state) do
    if Minga.Editing.in_leader?(state) and yields_to_leader?(state) do
      {:editor_view, :editor, 0}
    else
      scope_owner(state)
    end
  end

  defp normal_source_owner(state), do: scope_owner(state)

  defp yields_to_leader?(%{
         workspace: %{keymap_scope: :file_tree, file_tree: %{interaction: :browse}}
       }),
       do: true

  defp yields_to_leader?(%{workspace: %{keymap_scope: scope}})
       when scope in [:editor, :git_status, :queue],
       do: true

  # Agent chat and the file viewer yield every leader key to ModeFSM; a focused
  # composer stays agent-owned. Hover runs above this layer.
  defp yields_to_leader?(%{
         workspace: %{keymap_scope: :agent, agent_ui: %{panel: %{input_focused: false}}}
       }),
       do: true

  defp yields_to_leader?(_state), do: false

  defp scope_owner(%{
         workspace: %{keymap_scope: :editor, launchpad: %{}, editing: %{mode: :normal}}
       }),
       do: {:editor_view, :empty_state, 0}

  defp scope_owner(state), do: {:editor_view, scope_surface(state.workspace.keymap_scope), 0}

  defp scope_surface(:file_tree), do: :file_tree
  defp scope_surface(:agent), do: :agent
  defp scope_surface(:subagent_peek), do: :agent
  defp scope_surface(:git_status), do: :git_status
  defp scope_surface(:queue), do: :queue
  defp scope_surface(:editor), do: :editor
end
