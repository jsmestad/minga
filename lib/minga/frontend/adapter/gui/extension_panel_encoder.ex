defmodule Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.ExtensionPanel

  @spec encode(ExtensionPanel.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%ExtensionPanel{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_extension_panel_fp do
      {model.encoded, %{caches | last_extension_panel_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
