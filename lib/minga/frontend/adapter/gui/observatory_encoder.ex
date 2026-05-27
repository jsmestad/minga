defmodule Minga.Frontend.Adapter.GUI.ObservatoryEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Observatory

  @spec encode(Observatory.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Observatory{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_observatory_fp do
      {model.encoded, %{caches | last_observatory_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
