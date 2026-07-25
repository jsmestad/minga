defmodule MingaEditor.UI.Picker.WorkspaceSource do
  @moduledoc """
  Picker source that lists all workspaces.

  Shows workspace name, status, and tab count.
  The active workspace is marked. Selecting a workspace switches to it.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
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
      tab_count = Enum.count(tabs)
      status = agent_status_text(ws)

      # Show file names inline for context
      file_names =
        tabs
        |> Enum.filter(&(&1.kind == :file))
        |> Enum.map_join(", ", & &1.label)

      desc_parts = ["#{tab_count} tab#{if tab_count == 1, do: "", else: "s"}#{status}"]

      desc_parts =
        if file_names != "", do: Enum.concat(desc_parts, [file_names]), else: desc_parts

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
        %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state
      ) do
    target_id = TabBar.switch_to_workspace(tb, workspace_id).active_id
    if is_nil(target_id), do: state, else: MingaEditor.TabWorkflow.switch(state, target_id)
  end

  def on_select(_, state), do: state

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec group_icon(Workspace.t()) :: String.t()
  defp group_icon(%Workspace{}), do: "\u{F0256}"

  @spec agent_status_text(Workspace.t()) :: String.t()
  defp agent_status_text(%Workspace{payload: %WorkspaceAgent{agent_status: :thinking}}),
    do: " ↻ thinking"

  defp agent_status_text(%Workspace{payload: %WorkspaceAgent{agent_status: :tool_executing}}),
    do: " ⚙ executing"

  defp agent_status_text(%Workspace{payload: %WorkspaceAgent{agent_status: :plan}}), do: " ✎ plan"

  defp agent_status_text(%Workspace{payload: %WorkspaceAgent{agent_status: :error}}),
    do: " ⚠ error"

  defp agent_status_text(%Workspace{payload: %WorkspaceAgent{agent_status: :idle}}), do: " ✓ idle"
  defp agent_status_text(%Workspace{}), do: ""

  @spec status_annotation(Workspace.t()) :: String.t() | nil
  defp status_annotation(%Workspace{payload: %WorkspaceAgent{agent_status: :thinking}}),
    do: "↻ thinking"

  defp status_annotation(%Workspace{payload: %WorkspaceAgent{agent_status: :tool_executing}}),
    do: "⚙ executing"

  defp status_annotation(%Workspace{payload: %WorkspaceAgent{agent_status: :plan}}), do: "✎ plan"

  defp status_annotation(%Workspace{payload: %WorkspaceAgent{agent_status: :error}}),
    do: "⚠ error"

  defp status_annotation(%Workspace{payload: %WorkspaceAgent{agent_status: :idle}}), do: "✓ idle"
  defp status_annotation(%Workspace{}), do: nil
end
