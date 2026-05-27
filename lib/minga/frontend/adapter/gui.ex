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

  # Ordered list of {field, encoder_module} pairs for component encoding.
  # Each encoder exposes encode/2 that returns {binary(), Caches.t()}.
  @component_encoders [
    {:theme, ThemeEncoder},
    {:breadcrumb, BreadcrumbEncoder},
    {:which_key, WhichKeyEncoder},
    {:notifications, NotificationsEncoder},
    {:search_state, SearchStateEncoder},
    {:git_status, GitStatusEncoder},
    {:agent_context, AgentContextEncoder},
    {:status_bar, StatusBarEncoder},
    {:observatory, ObservatoryEncoder},
    {:board, BoardEncoder},
    {:tab_bar, TabBarEncoder},
    {:workspaces, WorkspacesEncoder},
    {:sidebars, SidebarsEncoder},
    {:file_tree, FileTreeEncoder},
    {:picker, PickerEncoder},
    {:minibuffer, MinibufferEncoder},
    {:completion, CompletionEncoder},
    {:signature_help, SignatureHelpEncoder},
    {:agent_chat, AgentChatEncoder},
    {:bottom_panel, BottomPanelEncoder},
    {:change_summary, ChangeSummaryEncoder},
    {:edit_timeline, EditTimelineEncoder},
    {:extension_overlay, ExtensionOverlayEncoder},
    {:extension_panel, ExtensionPanelEncoder},
    {:hover_popup, HoverPopupEncoder},
    {:float_popup, FloatPopupEncoder}
  ]

  @spec encode_ui(RenderModel.UI.t(), Caches.t()) :: {[binary()], Caches.t()}
  def encode_ui(%RenderModel.UI{} = ui, %Caches{} = caches) do
    {cmds, caches} =
      Enum.reduce(@component_encoders, {[], caches}, fn {field, encoder}, {cmds_acc, caches_acc} ->
        encode_component(Map.get(ui, field), encoder, cmds_acc, caches_acc)
      end)

    {Enum.reverse(cmds), caches}
  end

  @spec encode_component(term(), module(), [binary()], Caches.t()) :: {[binary()], Caches.t()}
  defp encode_component(nil, _encoder, cmds, caches), do: {cmds, caches}

  defp encode_component(value, encoder, cmds, caches) do
    {cmd, caches} = encoder.encode(value, caches)
    {[cmd | cmds], caches}
  end
end
