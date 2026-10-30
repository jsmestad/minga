defmodule MingaEditor.FocusOwner do
  @moduledoc "Derives keyboard ownership once at the editor-to-frame boundary."

  alias Minga.RenderModel.UI.FocusOwner
  alias MingaEditor.Input.InlineAsk
  alias MingaEditor.Input.InlineEdit
  alias MingaEditor.Input.InlineOverlay
  alias MingaEditor.Shell.Runtime
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

  defp modal_owner(:picker, {:picker, %{picker_ui: picker}}, _state),
    do: {:picker_query, :picker, picker.activation_offer.generation}

  # Pending trigger bookkeeping also uses the completion tag, but does not
  # claim input until the completion value has arrived.
  defp modal_owner(
         :completion,
         {:completion, %{completion: %Minga.Editing.Completion{}}},
         %{workspace: %{editing: %{mode: :insert}}} = state
       ),
       do: {:editor_view, :completion, ModalWorkflow.completion_generation(state)}

  # Scoped's agent trie claims Escape before command completion.
  defp modal_owner(
         :command_completion,
         _modal,
         %{workspace: %{keymap_scope: :agent}} = state
       ),
       do: search_owner(Search.gui_search_active?(state.workspace.search), :agent)

  # Command completion is handled by the editing model's command-mode handler,
  # not by Input.Completion (which only claims insert-mode completions).
  defp modal_owner(:command_completion, {:command_completion, %{generation: generation}}, _state),
    do: {:editor_view, :command_completion, generation}

  defp modal_owner(_tag, _modal, state) do
    search_owner(Search.gui_search_active?(state.workspace.search), state.workspace.keymap_scope)
  end

  defp search_owner(true, _scope), do: {:search_query, :search, 0}
  defp search_owner(false, :file_tree), do: {:editor_view, :file_tree, 0}
  defp search_owner(false, :agent), do: {:editor_view, :agent, 0}
  defp search_owner(false, :git_status), do: {:editor_view, :git_status, 0}
  defp search_owner(false, :editor), do: {:editor_view, :editor, 0}
end
