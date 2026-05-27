defmodule Minga.Frontend.Adapter.GUI do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.RenderModel

  @spec encode_ui(RenderModel.UI.t(), Caches.t()) :: {[binary()], Caches.t()}
  def encode_ui(%RenderModel.UI{} = ui, %Caches{} = caches) do
    {theme_cmd, caches} =
      if ui.theme, do: ThemeEncoder.encode(ui.theme, caches), else: {nil, caches}

    cmds = Enum.reject([theme_cmd], &is_nil/1)
    {cmds, caches}
  end
end
