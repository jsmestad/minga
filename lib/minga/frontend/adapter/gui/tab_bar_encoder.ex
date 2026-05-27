defmodule Minga.Frontend.Adapter.GUI.TabBarEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.TabBar

  @spec encode(TabBar.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%TabBar{encoded: nil}, %Caches{} = caches) do
    {nil, caches}
  end

  def encode(%TabBar{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_tab_bar_fp do
      {model.encoded, %{caches | last_tab_bar_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
