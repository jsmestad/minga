defmodule MingaEditor.RenderModel.UI.CompletionBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.RenderModel.UI.Completion
  alias MingaEditor.FoldMap
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Viewport

  @spec build(Context.t()) :: Completion.t()
  def build(%{completion: comp} = ctx) do
    {cursor_row, cursor_col} = current_cursor_screen_pos(ctx)
    fp = :erlang.phash2({comp, cursor_row, cursor_col})
    encoded = ProtocolGUI.encode_gui_completion(comp, cursor_row, cursor_col)

    %Completion{encoded: encoded, fingerprint: fp}
  end

  @spec current_cursor_screen_pos(Context.t()) :: {non_neg_integer(), non_neg_integer()}
  defp current_cursor_screen_pos(ctx) do
    active = ctx.windows.active
    layout = ctx.layout

    case {Map.get(layout.window_layouts, active), Map.get(ctx.windows.map, active)} do
      {%{content: {row, col, _w, _h}}, %{buffer: buf, viewport: viewport} = window}
      when is_pid(buf) ->
        {line, column} = Buffer.cursor(buf)
        total_lines = Buffer.line_count(buf)
        line_number_style = Buffer.get_option(buf, :line_numbers)

        number_width =
          if line_number_style == :none, do: 0, else: Viewport.gutter_width(total_lines)

        gutter_width = Gutter.total_width(number_width)
        visible_line = visible_cursor_line(window, line)

        {
          max(row + visible_line - viewport.top, 0),
          max(col + column + gutter_width - viewport.left, 0)
        }

      {%{content: {row, col, _w, _h}}, _window} ->
        {row, col}

      _ ->
        {0, 0}
    end
  catch
    :exit, _ -> {0, 0}
  end

  @spec visible_cursor_line(MingaEditor.Window.t(), non_neg_integer()) :: non_neg_integer()
  defp visible_cursor_line(%{fold_map: fold_map}, line) do
    if FoldMap.empty?(fold_map), do: line, else: FoldMap.buffer_to_visible(fold_map, line)
  end
end
