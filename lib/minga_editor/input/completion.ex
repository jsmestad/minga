defmodule MingaEditor.Input.Completion do
  @moduledoc """
  Input handler for the completion popup in insert mode.

  When a completion popup is visible and the editor is in insert mode,
  intercepts navigation keys (C-n, C-p, arrows), accept keys (Tab, Enter),
  and Escape. The wheel navigates the list and a backdrop click dismisses
  the popup. Candidate activation uses the displayed item's identity,
  not raw mouse coordinates. Other keys pass through to insert mode.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  import Bitwise

  alias Minga.Editing.Completion
  alias MingaEditor.CompletionHandling
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.State, as: EditorState

  @ctrl MingaEditor.Input.mod_ctrl()
  @escape 27
  @tab 9
  @enter 13
  @arrow_up_legacy 0x415B1B
  @arrow_down_legacy 0x425B1B
  @arrow_up_kitty 57_352
  @arrow_down_kitty 57_353
  @arrow_up_mac 0xF700
  @arrow_down_mac 0xF701

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{editing: %{mode: :insert}}} = state, cp, mods) do
    case MingaEditor.Shell.Traditional.ModalWorkflow.completion(state) do
      %Completion{} = completion ->
        case do_handle(state, completion, cp, mods) do
          {:handled, new_state} -> {:handled, new_state}
          :passthrough -> {:passthrough, state}
        end

      _ ->
        {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @impl true
  @spec handle_mouse_at_node(
          state(),
          FocusNode.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()

  # Completion popup active: intercept scroll and clicks routed by the focus tree.
  def handle_mouse_at_node(
        %{workspace: %{editing: %{mode: :insert}}} = state,
        %FocusNode{} = node,
        _row,
        _col,
        button,
        _mods,
        :press,
        _cc
      ) do
    case MingaEditor.Shell.Traditional.ModalWorkflow.completion(state) do
      %Completion{} ->
        do_handle_mouse(state, node, button)

      _ ->
        {:passthrough, state}
    end
  end

  def handle_mouse_at_node(state, _node, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end

  @spec do_handle_mouse(EditorState.t(), FocusNode.t(), atom()) ::
          MingaEditor.Input.Handler.result()
  defp do_handle_mouse(state, _node, :wheel_down) do
    {:handled,
     MingaEditor.Shell.Traditional.ModalWorkflow.navigate_completion(
       state,
       &Completion.move_down/1
     )}
  end

  defp do_handle_mouse(state, _node, :wheel_up) do
    {:handled,
     MingaEditor.Shell.Traditional.ModalWorkflow.navigate_completion(state, &Completion.move_up/1)}
  end

  defp do_handle_mouse(state, %FocusNode{content_type: :completion_backdrop}, :left) do
    {:handled, MingaEditor.do_dismiss_completion(state)}
  end

  defp do_handle_mouse(state, %FocusNode{content_type: :completion_menu}, :left) do
    {:handled, state}
  end

  defp do_handle_mouse(state, _node, _button), do: {:passthrough, state}

  # ── Key handling ─────────────────────────────────────────────────────────

  @spec do_handle(EditorState.t(), Completion.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | :passthrough

  # Escape: dismiss completion and stay in insert mode
  defp do_handle(state, _completion, @escape, _mods) do
    {:handled, MingaEditor.do_dismiss_completion(state)}
  end

  # C-n or arrow down: move selection down
  defp do_handle(state, _completion, cp, mods)
       when (cp == ?n and band(mods, @ctrl) != 0) or
              cp in [@arrow_down_legacy, @arrow_down_kitty, @arrow_down_mac] do
    state =
      MingaEditor.Shell.Traditional.ModalWorkflow.navigate_completion(
        state,
        &Completion.move_down/1
      )

    {:handled, CompletionHandling.maybe_resolve_selected(state)}
  end

  # C-p or arrow up: move selection up
  defp do_handle(state, _completion, cp, mods)
       when (cp == ?p and band(mods, @ctrl) != 0) or
              cp in [@arrow_up_legacy, @arrow_up_kitty, @arrow_up_mac] do
    state =
      MingaEditor.Shell.Traditional.ModalWorkflow.navigate_completion(
        state,
        &Completion.move_up/1
      )

    {:handled, CompletionHandling.maybe_resolve_selected(state)}
  end

  # Tab or Enter: accept the selected completion
  defp do_handle(state, completion, cp, _mods) when cp in [@tab, @enter] do
    new_state = MingaEditor.do_accept_completion(state, completion)
    {:handled, new_state}
  end

  # All other keys: pass through
  defp do_handle(_state, _completion, _cp, _mods), do: :passthrough
end
