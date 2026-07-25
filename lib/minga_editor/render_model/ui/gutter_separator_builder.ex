defmodule MingaEditor.RenderModel.UI.GutterSeparatorBuilder do
  @moduledoc false

  alias Minga.Config
  alias Minga.RenderModel.UI.GutterSeparator
  alias MingaEditor.Frontend.Emit.Context

  @spec build(Context.t()) :: GutterSeparator.t()
  def build(%Context{} = ctx) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)

    gutter_w = gutter_width(active_window)

    if show_separator?() and gutter_w > 0 do
      color = ctx.intent.frame.theme.gutter.separator_fg || ctx.intent.frame.theme.gutter.fg
      %GutterSeparator{col: gutter_w, color_rgb: color}
    else
      %GutterSeparator{col: 0, color_rgb: 0}
    end
  end

  @spec gutter_width(map() | nil) :: non_neg_integer()
  defp gutter_width(%{render_cache: cache}), do: max(Map.get(cache, :last_gutter_w, 0) || 0, 0)
  defp gutter_width(nil), do: 0

  @spec show_separator?() :: boolean()
  defp show_separator? do
    Config.get(:show_gutter_separator)
  catch
    :exit, _ -> false
  end
end
