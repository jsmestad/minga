defmodule MingaEditor.Input.Sidebar do
  @moduledoc """
  Generic input handler for extension-owned sidebars.

  The focus tree routes mouse events with the sidebar id in the node ref. Keyboard and mouse actions then flow through `MingaEditor.Extension.Sidebar.dispatch_action/4`, which returns a new editor state synchronously and participates in the normal editor action pipeline.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusTree.Node
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    case active_sidebar_id(state) do
      nil ->
        {:passthrough, state}

      sidebar_id ->
        {:handled,
         Sidebar.dispatch_action(state, sidebar_id, "key", %{
           codepoint: codepoint,
           modifiers: modifiers
         })}
    end
  end

  @impl true
  @spec handle_mouse_at_node(
          EditorState.t(),
          Node.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_mouse_at_node(
        state,
        %Node{ref: sidebar_id, rect: {top, left, _width, _height}},
        row,
        col,
        button,
        mods,
        event_type,
        click_count
      )
      when is_binary(sidebar_id) do
    context = %{
      row: row - top,
      col: col - left,
      button: button,
      modifiers: mods,
      event_type: event_type,
      click_count: click_count
    }

    {:handled, Sidebar.dispatch_action(state, sidebar_id, "mouse", context)}
  end

  def handle_mouse_at_node(state, _node, _row, _col, _button, _mods, _event_type, _click_count) do
    {:passthrough, state}
  end

  @spec active_sidebar_id(EditorState.t()) :: String.t() | nil
  defp active_sidebar_id(_state) do
    Sidebar.visible()
    |> Enum.reject(&(&1.id == "file_tree"))
    |> Enum.filter(&(&1.placement == :left))
    |> Enum.sort_by(&{not &1.focused?, &1.priority, &1.id})
    |> List.first()
    |> focused_sidebar_id()
  end

  @spec focused_sidebar_id(Sidebar.entry() | nil) :: String.t() | nil
  defp focused_sidebar_id(%{id: id, focused?: true}), do: id
  defp focused_sidebar_id(_sidebar), do: nil
end
