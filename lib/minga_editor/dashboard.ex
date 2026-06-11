defmodule MingaEditor.Dashboard do
  @moduledoc """
  Dashboard home screen state and item model.

  Holds the editor landing page's selectable items (quick-action shortcuts and
  recent files) and the cursor over them. The input layer
  (`MingaEditor.Input.Dashboard`) drives `cursor_up/1`, `cursor_down/1`, and
  `selected_command/1`.

  The cell-grid splash painter (`render/4` and its logo/item draw helpers) was
  removed in #2311. There is no semantic dashboard window builder yet, so the
  splash does not render on the semantic frontends; that gap is tracked
  separately (see #2311 notes). This module no longer produces any draws.
  """

  @typedoc "Command dispatched when a dashboard item is selected."
  @type command :: atom() | {:open_file, String.t()}

  @typedoc "Dashboard item: an action the user can select."
  @type item :: %{
          label: String.t(),
          shortcut: String.t(),
          command: command()
        }

  @typedoc "Dashboard state: cursor position and computed items."
  @type state :: %{
          cursor: non_neg_integer(),
          items: [item()]
        }

  @doc "Returns a fresh dashboard state with quick actions and recent files."
  @spec new_state([String.t()]) :: state()
  def new_state(recent_files \\ []) do
    items = quick_actions() ++ recent_file_items(recent_files)
    %{cursor: 0, items: items}
  end

  @doc "Moves the dashboard cursor up, wrapping at the top."
  @spec cursor_up(state()) :: state()
  def cursor_up(%{cursor: cursor, items: items} = state) do
    count = length(items)

    new_cursor =
      case count do
        0 -> 0
        _ -> rem(cursor - 1 + count, count)
      end

    %{state | cursor: new_cursor}
  end

  @doc "Moves the dashboard cursor down, wrapping at the bottom."
  @spec cursor_down(state()) :: state()
  def cursor_down(%{cursor: cursor, items: items} = state) do
    count = length(items)

    new_cursor =
      case count do
        0 -> 0
        _ -> rem(cursor + 1, count)
      end

    %{state | cursor: new_cursor}
  end

  @doc "Returns the command for the currently selected item, or nil if no items."
  @spec selected_command(state()) :: command() | nil
  def selected_command(%{cursor: cursor, items: items}) do
    case Enum.at(items, cursor) do
      nil -> nil
      item -> item.command
    end
  end

  # ── Items ─────────────────────────────────────────────────────────────────

  @spec quick_actions() :: [item()]
  defp quick_actions do
    [
      %{label: "Find file", shortcut: "SPC f f", command: :find_file},
      %{label: "Recent files", shortcut: "SPC f r", command: :project_recent_files},
      %{label: "New buffer", shortcut: "SPC b N", command: :new_buffer},
      %{label: "Agent session", shortcut: "SPC a a", command: :toggle_agentic_view},
      %{label: "Switch project", shortcut: "SPC p p", command: :project_switch}
    ]
  end

  @spec recent_file_items([String.t()]) :: [item()]
  defp recent_file_items(recent_files) do
    recent_files
    |> Enum.take(10)
    |> Enum.map(fn path ->
      %{label: path, shortcut: "", command: {:open_file, path}}
    end)
  end
end
