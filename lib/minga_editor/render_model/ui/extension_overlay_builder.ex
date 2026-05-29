defmodule MingaEditor.RenderModel.UI.ExtensionOverlayBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.ExtensionOverlay
  alias Minga.RenderModel.UI.ExtensionOverlay.Entry
  alias MingaEditor.Frontend.Emit.Context

  @spec build(Context.t()) :: ExtensionOverlay.t()
  def build(%Context{} = ctx) do
    %ExtensionOverlay{entries: build_overlay_entries(ctx)}
  end

  @spec build_overlay_entries(Context.t()) :: [Entry.t()]
  defp build_overlay_entries(ctx) do
    overlays = Minga.Extension.Overlay.all()

    if overlays == [] do
      []
    else
      Enum.flat_map(overlays, &resolve_overlay_to_entries(&1, ctx))
    end
  end

  @spec resolve_overlay_to_entries(Minga.Extension.Overlay.entry(), Context.t()) :: [Entry.t()]
  defp resolve_overlay_to_entries(overlay, ctx) do
    Enum.flat_map(ctx.layout.window_layouts, fn {win_id, win_layout} ->
      window = Map.get(ctx.windows.map, win_id)
      maybe_overlay_entry(overlay, window, win_id, win_layout)
    end)
  end

  @spec maybe_overlay_entry(
          Minga.Extension.Overlay.entry(),
          term(),
          pos_integer(),
          MingaEditor.Layout.window_layout()
        ) :: [Entry.t()]
  defp maybe_overlay_entry(overlay, %{buffer: buf} = window, win_id, win_layout)
       when is_pid(buf) do
    if buf == overlay.buffer do
      viewport_top = max(window.render_cache.last_viewport_top, 0)
      {_row, _col, _w, content_height} = win_layout.content
      {line, col} = overlay.position
      row = line - viewport_top

      if row >= 0 and row < content_height do
        style = overlay.style

        [
          %Entry{
            extension: to_string(overlay.extension),
            overlay_id: to_string(overlay.overlay_id),
            window_id: win_id,
            row: row,
            col: col,
            shape: overlay.shape,
            fg: Map.get(style, :fg, 0x51AFEF),
            opacity: Map.get(style, :opacity, 102),
            content: overlay.content
          }
        ]
      else
        []
      end
    else
      []
    end
  end

  defp maybe_overlay_entry(_overlay, _window, _win_id, _win_layout), do: []
end
