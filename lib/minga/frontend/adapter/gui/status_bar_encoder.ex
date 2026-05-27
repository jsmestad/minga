defmodule Minga.Frontend.Adapter.GUI.StatusBarEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.StatusBar

  @spec encode(StatusBar.t(), Caches.t()) :: {binary(), Caches.t()}
  def encode(%StatusBar{encoded: encoded}, %Caches{} = caches) do
    {encoded, caches}
  end
end
