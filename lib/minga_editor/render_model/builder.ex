defmodule MingaEditor.RenderModel.Builder do
  @moduledoc """
  Builds the top-level `Minga.RenderModel` for frontend adapters.
  """

  alias Minga.RenderModel
  alias Minga.RenderModel.UI
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.Builder, as: UIBuilder
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.ComposedFrame

  @spec build(ComposedFrame.t(), Context.t(), Chrome.t() | nil) :: {RenderModel.t(), Context.t()}
  def build(%ComposedFrame{} = frame, %Context{} = ctx, chrome \\ nil) do
    status_bar_data = chrome && chrome.status_bar_data
    minibuffer_data = chrome && chrome.minibuffer_data

    {ui, ctx} = UIBuilder.build_ui(ctx, status_bar_data, minibuffer_data)

    model =
      RenderModel.new(
        frame.windows,
        ui,
        frame.cursor,
        ctx.title,
        ctx.intent.frame.theme.editor.bg
      )

    {model, ctx}
  end

  @doc "Builds a render model with window content and frame side-channel fields only."
  @spec build_windows(ComposedFrame.t(), Context.t()) :: RenderModel.t()
  def build_windows(%ComposedFrame{} = frame, %Context{} = ctx) do
    RenderModel.new(
      frame.windows,
      %UI{},
      frame.cursor,
      ctx.title,
      ctx.intent.frame.theme.editor.bg
    )
  end
end
