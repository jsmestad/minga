defmodule MingaEditor.UI.Picker.WorkspaceSource do
  @moduledoc """
  Picker source that lists all workspaces.

  Shows workspace name, status, and tab count.
  The active workspace is marked. Selecting a workspace switches to it.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Design.Tokens
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaEditor.State.Workspace
  alias MingaEditor.State.TabBar

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch Workspace"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{tab_bar: %TabBar{} = tb} = ctx) do
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
      status = row_status(ws, tb, ctx)

      # Show file names inline for context
      file_names =
        tabs
        |> Enum.filter(&(&1.kind == :file))
        |> Enum.map_join(", ", & &1.label)

      desc_parts = [
        "#{tab_count} tab#{if tab_count == 1, do: "", else: "s"}#{status_text(status)}"
      ]

      desc_parts =
        if file_names != "", do: Enum.concat(desc_parts, [file_names]), else: desc_parts

      desc = Enum.join(desc_parts, " \u{2022} ")

      %Item{
        id: ws.id,
        label: "#{label}#{active_marker}",
        description: desc,
        annotation: status_annotation(status),
        icon_color: ws.color
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

  # Agent workspaces show the status that every other surface shows (WorkspaceStatus).
  # Manual workspaces have no Agent status.
  @spec row_status(Workspace.t(), TabBar.t(), Context.t()) :: WorkspaceStatus.t() | nil
  defp row_status(%Workspace{kind: :agent} = ws, %TabBar{} = tb, %Context{} = ctx) do
    WorkspaceStatus.resolve_in(
      ws,
      TabBar.active_workspace_id(tb),
      ctx.live_agent,
      ctx.live_agent_ui
    )
  end

  defp row_status(%Workspace{}, _tb, _ctx), do: nil

  # The row names the status with the state's mark and word from the token table, like the modeline.
  @spec status_text(WorkspaceStatus.t() | nil) :: String.t()
  defp status_text(status) do
    case status_annotation(status) do
      nil -> ""
      annotation -> " " <> annotation
    end
  end

  @spec status_annotation(WorkspaceStatus.t() | nil) :: String.t() | nil
  defp status_annotation(status) do
    case Tokens.agent_status_state(status) do
      nil -> nil
      state -> "#{Tokens.state(state).tui_glyph} #{Tokens.state_word(state)}"
    end
  end
end
