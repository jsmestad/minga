defmodule MingaEditor.RenderModel.UI.Builder do
  @moduledoc false

  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.ThemeBuilder
  alias Minga.RenderModel

  @spec build_ui(Context.t()) :: RenderModel.UI.t()
  def build_ui(%Context{} = ctx) do
    %RenderModel.UI{
      theme: ThemeBuilder.build(ctx.theme)
    }
  end
end
