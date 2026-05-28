defmodule MingaEditor.RenderModel.Builder do
  @moduledoc """
  Builds the top-level `Minga.RenderModel` for frontend adapters.

  The render pipeline still carries a `DisplayList.Frame` as a compatibility shell for TUI chrome during the migration. This builder extracts the semantic window models attached to that frame, builds UI chrome models, and returns one core render model that frontend adapters can encode or composite.
  """

  alias Minga.RenderModel
  alias Minga.RenderModel.Cursor
  alias Minga.RenderModel.UI
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.Frame
  alias MingaEditor.DisplayList.WindowFrame
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.Builder, as: UIBuilder
  alias MingaEditor.RenderPipeline.Chrome

  @spec build(Frame.t(), Context.t(), Chrome.t() | nil) :: {RenderModel.t(), Context.t()}
  def build(%Frame{} = frame, %Context{} = ctx, chrome \\ nil) do
    status_bar_data = chrome && chrome.status_bar_data
    minibuffer_data = chrome && chrome.minibuffer_data

    {ui, ctx} = UIBuilder.build_ui(ctx, status_bar_data, minibuffer_data)

    model =
      RenderModel.new(
        window_models(frame),
        ui,
        cursor_model(frame.cursor),
        ctx.title,
        ctx.theme.editor.bg
      )

    {model, ctx}
  end

  @doc "Builds a render model with window content and frame side-channel fields only."
  @spec build_windows(Frame.t(), Context.t()) :: RenderModel.t()
  def build_windows(%Frame{} = frame, %Context{} = ctx) do
    RenderModel.new(
      window_models(frame),
      %UI{},
      cursor_model(frame.cursor),
      ctx.title,
      ctx.theme.editor.bg
    )
  end

  @spec window_models(Frame.t()) :: [RenderModel.Window.t()]
  defp window_models(%Frame{} = frame) do
    Enum.flat_map(frame.windows, fn %WindowFrame{} = wf ->
      [wf.window_model | wf.additional_window_models]
      |> Enum.reject(&is_nil/1)
    end)
  end

  @spec cursor_model(DisplayList.Cursor.t()) :: Cursor.t()
  defp cursor_model(%DisplayList.Cursor{row: row, col: col, shape: shape}) do
    Cursor.new(row, col, shape)
  end
end
