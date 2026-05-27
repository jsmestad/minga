defmodule Minga.Frontend.Adapter.GUI.CompletionEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Completion

  @spec encode(Completion.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Completion{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_completion_fp do
      {model.encoded, %{caches | last_completion_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
