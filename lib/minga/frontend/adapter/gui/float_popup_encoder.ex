defmodule Minga.Frontend.Adapter.GUI.FloatPopupEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.FloatPopup

  @spec encode(FloatPopup.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%FloatPopup{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_float_popup_fp do
      {model.encoded, %{caches | last_float_popup_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
