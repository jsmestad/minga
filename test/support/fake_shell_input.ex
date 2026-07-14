defmodule MingaEditor.Test.FakeShellInput do
  @moduledoc "Test-only input handler proving extension shell dispatch uses the active Runtime entry."

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_key(
          MingaEditor.Input.Handler.handler_state(),
          non_neg_integer(),
          non_neg_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_key(%EditorState{} = state, ?x, 0) do
    {runtime, workspace} = Runtime.route_event(state.shell_runtime, state.workspace, :input_probe)

    state =
      state
      |> then(fn state -> %{state | shell_runtime: runtime} end)
      |> then(fn state -> %{state | workspace: workspace} end)

    {:handled, state}
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  @impl true
  @spec handle_mouse_at_node(
          MingaEditor.Input.Handler.handler_state(),
          MingaEditor.FocusTree.Node.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_mouse_at_node(state, _node, _row, _col, _button, _mods, _event_type, _click_count),
    do: {:passthrough, state}
end
