defmodule Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.ChangeSummary

  @spec encode(ChangeSummary.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%ChangeSummary{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_change_summary_fp do
      {model.encoded, %{caches | last_change_summary_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
