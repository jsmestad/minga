defmodule Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.ExtensionOverlay

  @spec encode(ExtensionOverlay.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%ExtensionOverlay{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_extension_overlay_fp do
      {model.encoded, %{caches | last_extension_overlay_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
