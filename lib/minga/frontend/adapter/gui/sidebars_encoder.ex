defmodule Minga.Frontend.Adapter.GUI.SidebarsEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Sidebars

  @spec encode(Sidebars.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Sidebars{encoded: nil}, %Caches{} = caches) do
    {nil, caches}
  end

  def encode(%Sidebars{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_sidebars_fp do
      {model.encoded, %{caches | last_sidebars_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
