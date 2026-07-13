defmodule MingaEditor.Input.BottomPanel do
  @moduledoc """
  Mouse handler for the Semantic UI bottom panel.

  The bottom panel is not a `WindowTree` leaf, but it is still an interactive surface. Clicking it focuses the panel so window navigation can move into and out of it without routing the click to the underlying editor buffer.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.BottomPanel
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    panel = EditorState.bottom_panel(state)

    if BottomPanel.focused?(panel) do
      handle_focused_key(state, panel, codepoint, modifiers)
    else
      {:passthrough, state}
    end
  end

  @spec handle_focused_key(EditorState.t(), BottomPanel.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_focused_key(state, panel, ?q, 0) do
    if Minga.Editing.active_model(state) == Minga.Editing.Model.Vim and
         Minga.Editing.mode(state) == :normal do
      {:handled, close_panel(state, panel)}
    else
      {:handled, state}
    end
  end

  defp handle_focused_key(state, panel, 27, 0) do
    if Minga.Editing.active_model(state) == Minga.Editing.Model.CUA do
      {:handled, close_panel(state, panel)}
    else
      {:passthrough, state}
    end
  end

  defp handle_focused_key(state, _panel, codepoint, modifiers) do
    if vim_leader_key?(state, codepoint, modifiers) or
         MingaEditor.Input.key_sequence_pending?(state) do
      {:passthrough, state}
    else
      {:handled, state}
    end
  end

  @spec vim_leader_key?(EditorState.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp vim_leader_key?(state, ?\s, 0) do
    Minga.Editing.active_model(state) == Minga.Editing.Model.Vim and
      Minga.Editing.mode(state) == :normal
  end

  defp vim_leader_key?(_state, _codepoint, _modifiers), do: false

  @spec close_panel(EditorState.t(), BottomPanel.t()) :: EditorState.t()
  defp close_panel(state, panel) do
    state
    |> EditorState.set_bottom_panel(BottomPanel.hide(panel))
    |> EditorState.set_keymap_scope(
      MingaEditor.Session.State.scope_for_active_window(state.workspace)
    )
  end

  @impl true
  @spec handle_mouse_at_node(
          EditorState.t(),
          FocusNode.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_mouse_at_node(
        state,
        %FocusNode{content_type: :bottom_panel},
        _row,
        _col,
        :left,
        _mods,
        :press,
        _click_count
      ) do
    panel = state |> EditorState.bottom_panel() |> BottomPanel.focus()

    state =
      state
      |> EditorState.set_bottom_panel(panel)
      |> EditorState.update_file_tree(&FileTreeState.unfocus/1)
      |> EditorState.set_keymap_scope(
        MingaEditor.Session.State.scope_for_active_window(state.workspace)
      )

    {:handled, state}
  end

  def handle_mouse_at_node(
        state,
        %FocusNode{content_type: :bottom_panel},
        _row,
        _col,
        _button,
        _mods,
        _event_type,
        _click_count
      ) do
    {:handled, state}
  end

  def handle_mouse_at_node(state, _node, _row, _col, _button, _mods, _event_type, _click_count) do
    {:passthrough, state}
  end
end
