defmodule MingaEditor.Input.ActMenu do
  @moduledoc "Routes keys to the shared act-menu offer before its parent surface."

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.Input.Handler
  alias MingaEditor.Shell.Traditional.ActMenu
  alias MingaEditor.Shell.Traditional.ActMenuWorkflow
  alias MingaEditor.State

  @impl true
  @spec handle_key(State.t(), non_neg_integer(), non_neg_integer()) :: Handler.result()
  def handle_key(state, codepoint, modifiers) do
    case ActMenuWorkflow.current(state) do
      nil -> open_for_input(state, codepoint, modifiers)
      menu -> {:handled, route_key(state, menu, codepoint, modifiers)}
    end
  end

  @impl true
  @spec handle_paste(State.t(), String.t()) :: Handler.result()
  def handle_paste(state, text) do
    case ActMenuWorkflow.current(state) do
      nil -> {:passthrough, state}
      menu -> {:handled, ActMenuWorkflow.replace(state, ActMenu.filter(menu, text))}
    end
  end

  @impl true
  @spec handle_mouse_at_node(
          State.t(),
          MingaEditor.FocusTree.Node.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: Handler.result()
  def handle_mouse_at_node(state, _node, _row, _column, _button, _modifiers, event, _count) do
    case ActMenuWorkflow.current(state) do
      nil -> {:passthrough, state}
      _menu when event == :press -> {:handled, ActMenuWorkflow.replace(state, nil)}
      _menu -> {:handled, state}
    end
  end

  @spec open_for_input(State.t(), non_neg_integer(), non_neg_integer()) :: Handler.result()
  defp open_for_input(state, ?., 0x02) do
    case ActMenuWorkflow.open_for_typing(state) do
      {:handled, _} = result -> result
      :unbound -> {:passthrough, state}
    end
  end

  defp open_for_input(state, _codepoint, _modifiers), do: {:passthrough, state}

  @spec route_key(State.t(), ActMenu.t(), non_neg_integer(), non_neg_integer()) :: State.t()
  defp route_key(state, _menu, 27, 0), do: ActMenuWorkflow.replace(state, nil)
  defp route_key(state, _menu, ?., 0x02), do: ActMenuWorkflow.replace(state, nil)

  defp route_key(state, menu, 13, 0),
    do: ActMenuWorkflow.choose(state, menu, ActMenu.selected(menu))

  defp route_key(state, menu, ?/, 0),
    do: ActMenuWorkflow.replace(state, ActMenu.begin_filter(menu))

  defp route_key(state, menu, codepoint, 0) when codepoint in [8, 127],
    do: ActMenuWorkflow.replace(state, ActMenu.backspace(menu))

  defp route_key(state, menu, codepoint, 0) when codepoint in [57_352, 0xF700],
    do: ActMenuWorkflow.replace(state, ActMenu.move(menu, -1))

  defp route_key(state, menu, codepoint, 0) when codepoint in [57_353, 0xF701],
    do: ActMenuWorkflow.replace(state, ActMenu.move(menu, 1))

  defp route_key(state, menu, ?k, 0x02),
    do: ActMenuWorkflow.replace(state, ActMenu.move(menu, -1))

  defp route_key(state, menu, ?j, 0x02), do: ActMenuWorkflow.replace(state, ActMenu.move(menu, 1))

  defp route_key(state, menu, codepoint, modifiers)
       when modifiers in [0, 1] and codepoint in 32..0x10FFFF and codepoint not in 0xD800..0xDFFF do
    key = <<codepoint::utf8>>

    cond do
      action = ActMenu.shortcut(menu, key) -> ActMenuWorkflow.choose(state, menu, action)
      String.printable?(key) -> ActMenuWorkflow.replace(state, ActMenu.filter(menu, key))
      true -> state
    end
  end

  defp route_key(state, _menu, _codepoint, _modifiers), do: state
end
