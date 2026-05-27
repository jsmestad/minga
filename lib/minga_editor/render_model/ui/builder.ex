defmodule MingaEditor.RenderModel.UI.Builder do
  @moduledoc false

  alias MingaEditor.Frontend.Emit.Context
  alias Minga.RenderModel

  @spec build_ui(Context.t()) :: RenderModel.UI.t()
  def build_ui(%Context{} = _ctx) do
    # Component builders will be added here as they migrate.
    %RenderModel.UI{}
  end
end
