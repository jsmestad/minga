defmodule MingaEditor.UI.Picker.WorkspaceSource do
  @moduledoc """
  Picker source that lists all workspaces.

  Shows workspace name, status, and tab count.
  The active workspace is marked. Selecting a workspace switches to it.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.TabBar

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch Workspace"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{tab_bar: %TabBar{} = tb}) do
    # Filter out workspaces with no tabs (empty manual workspace)
    tb.workspaces
    |> Enum.filter(fn ws ->
      TabBar.tabs_in_workspace(tb, ws.id) != []
    end)
    |> Enum.map(fn ws ->
      icon = group_icon(ws)
      label = "#{icon} #{ws.label}"
      active_marker = if ws.id == TabBar.active_workspace_id(tb), do: " \u{2022}", else: ""
      tabs = TabBar.tabs_in_workspace(tb, ws.id)
      tab_count = length(tabs)
      status = agent_status_text(ws)

      # Show file names inline for context
      file_names =
        tabs
        |> Enum.filter(&(&1.kind == :file))
        |> Enum.map_join(", ", & &1.label)

      desc_parts = ["#{tab_count} tab#{if tab_count == 1, do: "", else: "s"}#{status}"]
      desc_parts = if file_names != "", do: desc_parts ++ [file_names], else: desc_parts
      desc = Enum.join(desc_parts, " \u{2022} ")

      %Item{
        id: ws.id,
        label: "#{label}#{active_marker}",
        description: desc,
        annotation: status_annotation(ws),
        icon_color: ws.color,
        two_line: true
      }
    end)
  end

  def candidates(_), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(
        %Item{id: workspace_id},
        %{shell_state: %{tab_bar: %TabBar{} = tb}} = state
      ) do
    target_id = TabBar.switch_to_workspace(tb, workspace_id).active_id
    EditorState.switch_tab(state, target_id)
  end

  def on_select(_, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec group_icon(Workspace.t()) :: String.t()
  defp group_icon(%Workspace{}), do: "\u{F024B}"

  @spec agent_status_text(Workspace.t()) :: String.t()
  defp agent_status_text(%Workspace{agent_status: :thinking}),
    do: " \u{21BB} thinking"

  defp agent_status_text(%Workspace{agent_status: :tool_executing}),
    do: " \u{2699} executing"

  defp agent_status_text(%Workspace{agent_status: :plan}), do: " ✎ plan"
  defp agent_status_text(%Workspace{agent_status: :error}), do: " \u{26A0} error"
  defp agent_status_text(%Workspace{agent_status: :idle}), do: " \u{2713} idle"
  defp agent_status_text(_), do: ""

  @spec status_annotation(Workspace.t()) :: String.t() | nil
  defp status_annotation(%Workspace{agent_status: :thinking}),
    do: "\u{21BB} thinking"

  defp status_annotation(%Workspace{agent_status: :tool_executing}),
    do: "\u{2699} executing"

  defp status_annotation(%Workspace{agent_status: :plan}), do: "✎ plan"
  defp status_annotation(%Workspace{agent_status: :error}), do: "\u{26A0} error"
  defp status_annotation(%Workspace{agent_status: :idle}), do: "\u{2713} idle"
  defp status_annotation(_), do: nil
end
