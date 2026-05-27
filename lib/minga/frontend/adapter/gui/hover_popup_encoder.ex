defmodule Minga.Frontend.Adapter.GUI.HoverPopupEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.HoverPopup

  @spec encode(HoverPopup.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%HoverPopup{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_hover_popup_fp do
      {model.encoded, %{caches | last_hover_popup_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
