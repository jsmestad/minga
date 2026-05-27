defmodule Minga.Frontend.Adapter.GUI do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
  alias Minga.Frontend.Adapter.GUI.AgentContextEncoder
  alias Minga.Frontend.Adapter.GUI.BoardEncoder
  alias Minga.Frontend.Adapter.GUI.BottomPanelEncoder
  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.Frontend.Adapter.GUI.EditTimelineEncoder
  alias Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoder
  alias Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.Frontend.Adapter.GUI.FloatPopupEncoder
  alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
  alias Minga.Frontend.Adapter.GUI.HoverPopupEncoder
  alias Minga.Frontend.Adapter.GUI.MinibufferEncoder
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.Frontend.Adapter.GUI.NotificationsEncoder
  alias Minga.Frontend.Adapter.GUI.ObservatoryEncoder
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias Minga.Frontend.Adapter.GUI.SignatureHelpEncoder
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

    {file_tree_cmd, caches} =
      if ui.file_tree,
        do: FileTreeEncoder.encode(ui.file_tree, caches),
        else: {nil, caches}

    {picker_cmd, caches} =
      if ui.picker,
        do: PickerEncoder.encode(ui.picker, caches),
        else: {nil, caches}

    {minibuffer_cmd, caches} =
      if ui.minibuffer,
        do: MinibufferEncoder.encode(ui.minibuffer, caches),
        else: {nil, caches}

    {completion_cmd, caches} =
      if ui.completion,
        do: CompletionEncoder.encode(ui.completion, caches),
        else: {nil, caches}

    {signature_help_cmd, caches} =
      if ui.signature_help,
        do: SignatureHelpEncoder.encode(ui.signature_help, caches),
        else: {nil, caches}

    {agent_chat_cmd, caches} =
      if ui.agent_chat,
        do: AgentChatEncoder.encode(ui.agent_chat, caches),
        else: {nil, caches}

    {bottom_panel_cmd, caches} =
      if ui.bottom_panel,
        do: BottomPanelEncoder.encode(ui.bottom_panel, caches),
        else: {nil, caches}

    {change_summary_cmd, caches} =
      if ui.change_summary,
        do: ChangeSummaryEncoder.encode(ui.change_summary, caches),
        else: {nil, caches}

    {edit_timeline_cmd, caches} =
      if ui.edit_timeline,
        do: EditTimelineEncoder.encode(ui.edit_timeline, caches),
        else: {nil, caches}

    {extension_overlay_cmd, caches} =
      if ui.extension_overlay,
        do: ExtensionOverlayEncoder.encode(ui.extension_overlay, caches),
        else: {nil, caches}

    {extension_panel_cmd, caches} =
      if ui.extension_panel,
        do: ExtensionPanelEncoder.encode(ui.extension_panel, caches),
        else: {nil, caches}

    {hover_popup_cmd, caches} =
      if ui.hover_popup,
        do: HoverPopupEncoder.encode(ui.hover_popup, caches),
        else: {nil, caches}

    {float_popup_cmd, caches} =
      if ui.float_popup,
        do: FloatPopupEncoder.encode(ui.float_popup, caches),
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
          sidebars_cmd,
          file_tree_cmd,
          picker_cmd,
          minibuffer_cmd,
          completion_cmd,
          signature_help_cmd,
          agent_chat_cmd,
          bottom_panel_cmd,
          change_summary_cmd,
          edit_timeline_cmd,
          extension_overlay_cmd,
          extension_panel_cmd,
          hover_popup_cmd,
          float_popup_cmd
        ],
        &is_nil/1
      )

    {cmds, caches}
  end
end
