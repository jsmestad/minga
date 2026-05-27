defmodule Minga.Frontend.Adapter.GUI.EditTimelineEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.EditTimeline

  @spec encode(EditTimeline.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%EditTimeline{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_edit_timeline_fp do
      {model.encoded, %{caches | last_edit_timeline_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
