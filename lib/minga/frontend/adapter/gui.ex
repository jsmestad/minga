defmodule Minga.Frontend.Adapter.GUI do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.AgentContextEncoder
  alias Minga.Frontend.Adapter.GUI.BoardEncoder
  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
  alias Minga.Frontend.Adapter.GUI.NotificationsEncoder
  alias Minga.Frontend.Adapter.GUI.ObservatoryEncoder
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias Minga.Frontend.Adapter.GUI.SidebarsEncoder
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.Frontend.Adapter.GUI.TabBarEncoder
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.Frontend.Adapter.GUI.WhichKeyEncoder
  alias Minga.Frontend.Adapter.GUI.WorkspacesEncoder
  alias Minga.RenderModel

  @spec encode_ui(RenderModel.UI.t(), Caches.t()) :: {[binary()], Caches.t()}
  def encode_ui(%RenderModel.UI{} = ui, %Caches{} = caches) do
    {theme_cmd, caches} =
      if ui.theme, do: ThemeEncoder.encode(ui.theme, caches), else: {nil, caches}

    {breadcrumb_cmd, caches} =
      if ui.breadcrumb, do: BreadcrumbEncoder.encode(ui.breadcrumb, caches), else: {nil, caches}

    {which_key_cmd, caches} =
      if ui.which_key, do: WhichKeyEncoder.encode(ui.which_key, caches), else: {nil, caches}

    {notifications_cmd, caches} =
      if ui.notifications,
        do: NotificationsEncoder.encode(ui.notifications, caches),
        else: {nil, caches}

    {search_state_cmd, caches} =
      if ui.search_state,
        do: SearchStateEncoder.encode(ui.search_state, caches),
        else: {nil, caches}

    {git_status_cmd, caches} =
      if ui.git_status,
        do: GitStatusEncoder.encode(ui.git_status, caches),
        else: {nil, caches}

    {agent_context_cmd, caches} =
      if ui.agent_context,
        do: AgentContextEncoder.encode(ui.agent_context, caches),
        else: {nil, caches}

    {status_bar_cmd, caches} =
      if ui.status_bar,
        do: StatusBarEncoder.encode(ui.status_bar, caches),
        else: {nil, caches}

    {observatory_cmd, caches} =
      if ui.observatory,
        do: ObservatoryEncoder.encode(ui.observatory, caches),
        else: {nil, caches}

    {board_cmd, caches} =
      if ui.board,
        do: BoardEncoder.encode(ui.board, caches),
        else: {nil, caches}

    {tab_bar_cmd, caches} =
      if ui.tab_bar,
        do: TabBarEncoder.encode(ui.tab_bar, caches),
        else: {nil, caches}

    {workspaces_cmd, caches} =
      if ui.workspaces,
        do: WorkspacesEncoder.encode(ui.workspaces, caches),
        else: {nil, caches}

    {sidebars_cmd, caches} =
      if ui.sidebars,
        do: SidebarsEncoder.encode(ui.sidebars, caches),
        else: {nil, caches}

    cmds =
      Enum.reject(
        [
          theme_cmd,
          breadcrumb_cmd,
          which_key_cmd,
          notifications_cmd,
          search_state_cmd,
          git_status_cmd,
          agent_context_cmd,
          status_bar_cmd,
          observatory_cmd,
          board_cmd,
          tab_bar_cmd,
          workspaces_cmd,
          sidebars_cmd
        ],
        &is_nil/1
      )

    {cmds, caches}
  end
end
