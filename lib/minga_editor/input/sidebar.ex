defmodule MingaEditor.Input.Sidebar do
  @moduledoc """
  Generic input handler for sidebars that do not provide a specialized input handler.

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
    case active_sidebar(state) do
      %{input_handler: handler} when handler not in [nil, __MODULE__] ->
        {:passthrough, state}

      %{id: sidebar_id} ->
        {:handled,
         Sidebar.dispatch_action(EditorState.sidebar_registry(state), state, sidebar_id, "key", %{
           codepoint: codepoint,
           modifiers: modifiers
         })}

      nil ->
        {:passthrough, state}
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

    {:handled,
     Sidebar.dispatch_action(
       EditorState.sidebar_registry(state),
       state,
       sidebar_id,
       "mouse",
       context
     )}
  end

  def handle_mouse_at_node(state, _node, _row, _col, _button, _mods, _event_type, _click_count) do
    {:passthrough, state}
  end

  @spec active_sidebar(EditorState.t()) :: Sidebar.entry() | nil
  defp active_sidebar(state) do
    state
    |> EditorState.sidebar_registry()
    |> Sidebar.active_left()
    |> focused_sidebar()
  end

  @spec focused_sidebar(Sidebar.entry() | nil) :: Sidebar.entry() | nil
  defp focused_sidebar(%{focused?: true} = sidebar), do: sidebar
  defp focused_sidebar(_sidebar), do: nil
end
