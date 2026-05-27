defmodule Minga.Frontend.Adapter.GUI do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.Frontend.Adapter.GUI.WhichKeyEncoder
  alias Minga.RenderModel

  @spec encode_ui(RenderModel.UI.t(), Caches.t()) :: {[binary()], Caches.t()}
  def encode_ui(%RenderModel.UI{} = ui, %Caches{} = caches) do
    {theme_cmd, caches} =
      if ui.theme, do: ThemeEncoder.encode(ui.theme, caches), else: {nil, caches}

    {breadcrumb_cmd, caches} =
      if ui.breadcrumb, do: BreadcrumbEncoder.encode(ui.breadcrumb, caches), else: {nil, caches}

    {which_key_cmd, caches} =
      if ui.which_key, do: WhichKeyEncoder.encode(ui.which_key, caches), else: {nil, caches}

    cmds = Enum.reject([theme_cmd, breadcrumb_cmd, which_key_cmd], &is_nil/1)
    {cmds, caches}
  end
end
