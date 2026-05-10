defmodule Minga.Test.InputRouterMouseProbe do
  @moduledoc "Test-only mouse handler that records focus-tree dispatch order."

  @behaviour MingaEditor.Input.Handler

  @impl true
  @spec handle_key(
          MingaEditor.Input.Handler.handler_state(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          MingaEditor.Input.Handler.result()
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
  def handle_mouse_at_node(state, node, _row, _col, _button, _mods, _event_type, _click_count) do
    send(self(), {:mouse_probe, node.content_type, node.ref})

    case node.ref do
      {:pass, _tag} -> {:passthrough, state}
      :pass -> {:passthrough, state}
      _ -> {:handled, state}
    end
  end
end
