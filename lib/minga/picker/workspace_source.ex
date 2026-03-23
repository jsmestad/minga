defmodule Minga.Picker.WorkspaceSource do
  @moduledoc """
  Picker source that lists all workspaces.

  Shows workspace name, kind (manual/agent), agent status, and tab count.
  The active workspace is marked. Selecting a workspace switches to it.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Picker.Item

  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Workspace

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch Workspace"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(%{tab_bar: %TabBar{} = tb}) do
    Enum.map(tb.workspaces, fn ws ->
      icon = workspace_icon(ws)
      label = "#{icon} #{ws.label}"
      active_marker = if ws.id == tb.active_workspace_id, do: " \u{2022}", else: ""
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
  def on_select(%Item{id: workspace_id}, %{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.switch_workspace(tb, workspace_id)}
  end

  def on_select(_, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec workspace_icon(Workspace.t()) :: String.t()
  defp workspace_icon(%Workspace{kind: :manual}), do: "\u{F024B}"
  defp workspace_icon(%Workspace{kind: :agent}), do: "\u{F0BA0}"

  @spec agent_status_text(Workspace.t()) :: String.t()
  defp agent_status_text(%Workspace{kind: :agent, agent_status: :thinking}),
    do: " \u{21BB} thinking"

  defp agent_status_text(%Workspace{kind: :agent, agent_status: :tool_executing}),
    do: " \u{2699} executing"

  defp agent_status_text(%Workspace{kind: :agent, agent_status: :error}), do: " \u{26A0} error"
  defp agent_status_text(%Workspace{kind: :agent, agent_status: :idle}), do: " \u{2713} idle"
  defp agent_status_text(_), do: ""

  @spec status_annotation(Workspace.t()) :: String.t() | nil
  defp status_annotation(%Workspace{kind: :agent, agent_status: :thinking}),
    do: "\u{21BB} thinking"

  defp status_annotation(%Workspace{kind: :agent, agent_status: :tool_executing}),
    do: "\u{2699} executing"

  defp status_annotation(%Workspace{kind: :agent, agent_status: :error}), do: "\u{26A0} error"
  defp status_annotation(%Workspace{kind: :agent, agent_status: :idle}), do: "\u{2713} idle"
  defp status_annotation(_), do: nil
end
