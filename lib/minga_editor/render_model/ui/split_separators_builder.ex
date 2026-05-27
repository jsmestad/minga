defmodule MingaEditor.RenderModel.UI.SplitSeparatorsBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.SplitSeparators
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Shell.Traditional.Chrome.Helpers, as: ChromeHelpers

  @spec build(Context.t()) :: SplitSeparators.t()
  def build(%Context{} = ctx) do
    if MingaEditor.State.Windows.split?(ctx.windows) do
      %SplitSeparators{
        border_color_rgb: ctx.theme.editor.split_border_fg,
        verticals:
          ChromeHelpers.collect_vertical_separators(ctx.windows.tree, ctx.layout.editor_area),
        horizontals: ctx.layout.horizontal_separators
      }
    else
      %SplitSeparators{border_color_rgb: 0, verticals: [], horizontals: []}
    end
  end
end
