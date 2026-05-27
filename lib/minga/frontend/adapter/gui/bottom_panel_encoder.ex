defmodule Minga.Frontend.Adapter.GUI.BottomPanelEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.BottomPanel

  @spec encode(BottomPanel.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%BottomPanel{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_bottom_panel_fp do
      {model.encoded, %{caches | last_bottom_panel_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
