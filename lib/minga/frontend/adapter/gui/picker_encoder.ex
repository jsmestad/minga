defmodule Minga.Frontend.Adapter.GUI.PickerEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Picker

  @spec encode(Picker.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Picker{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_picker_fp do
      {model.encoded, %{caches | last_picker_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
