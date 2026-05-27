defmodule Minga.Frontend.Adapter.GUI.MinibufferEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Minibuffer

  @spec encode(Minibuffer.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Minibuffer{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_minibuffer_fp do
      {model.encoded, %{caches | last_minibuffer_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
