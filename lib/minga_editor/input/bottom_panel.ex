defmodule MingaEditor.Input.BottomPanel do
  @moduledoc """
  Mouse handler for the Semantic UI bottom panel.

  The bottom panel is not a `WindowTree` leaf, but it is still an interactive surface. Clicking it focuses the panel so window navigation can move into and out of it without routing the click to the underlying editor buffer.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.BottomPanel
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.Session.State
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    panel = state.shell_runtime.state.bottom_panel

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
    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_bottom_panel(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          MingaEditor.BottomPanel.hide(panel)
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
    |> then(fn state ->
      %{
        state
        | workspace:
            State.set_keymap_scope(
              state.workspace,
              State.scope_for_active_window(state.workspace)
            )
      }
    end)
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
    panel = state.shell_runtime.state.bottom_panel |> BottomPanel.focus()

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_bottom_panel(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            panel
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
      |> then(fn state ->
        %{
          state
          | workspace:
              State.set_file_tree(
                state.workspace,
                (&FileTreeState.unfocus/1).(state.workspace.file_tree)
              )
        }
      end)
      |> then(fn state ->
        %{
          state
          | workspace:
              State.set_keymap_scope(
                state.workspace,
                State.scope_for_active_window(state.workspace)
              )
        }
      end)

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
