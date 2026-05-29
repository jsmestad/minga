defmodule MingaEditor.RenderModel.UI.ExtensionPanelBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.ExtensionPanel
  alias Minga.RenderModel.UI.ExtensionPanel.Panel

  @spec build() :: ExtensionPanel.t()
  def build do
    panels = Minga.Extension.Panel.visible()
    %ExtensionPanel{panels: Enum.map(panels, &panel_model/1)}
  end

  @spec panel_model(Minga.Extension.Panel.entry()) :: Panel.t()
  defp panel_model(panel) do
    %Panel{
      extension: to_string(panel.extension),
      panel_id: to_string(panel.panel_id),
      title: panel.title,
      position: panel.position,
      size: panel.size,
      visible?: panel.visible,
      content: panel.content
    }
  end
end
