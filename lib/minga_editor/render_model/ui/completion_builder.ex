defmodule MingaEditor.RenderModel.UI.CompletionBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.Editing.Completion, as: EditingCompletion
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.Completion.Item
  alias MingaEditor.FoldMap
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Viewport

  # Cap the selected item's documentation at 4 KiB of UTF-8. Docs re-emit on
  # every selection move, so a small cap keeps the per-keystroke payload bounded.
  # The wire field is a string16 (max 65535 bytes); this cap is the product
  # decision, documented in docs/protocol_schema.toml under gui_completion.
  @doc_byte_cap 4096

  @spec build(Context.t()) :: Completion.t()
  def build(%{completion: comp} = ctx) do
    {cursor_row, cursor_col} = current_cursor_screen_pos(ctx)
    completion_model(comp, cursor_row, cursor_col)
  end

  @spec completion_model(EditingCompletion.t() | nil, non_neg_integer(), non_neg_integer()) ::
          Completion.t()
  defp completion_model(nil, _cursor_row, _cursor_col), do: %Completion{}

  defp completion_model(%EditingCompletion{} = comp, cursor_row, cursor_col) do
    {items, selected_offset} = EditingCompletion.visible_items(comp)

    case items do
      [] ->
        %Completion{}

      visible_items ->
        %Completion{
          visible?: true,
          cursor_row: cursor_row,
          cursor_col: cursor_col,
          selected_offset: selected_offset,
          items: Enum.map(visible_items, &item_model/1),
          documentation: selected_documentation(comp)
        }
    end
  end

  # The selected item's documentation (markdown or plaintext from the LSP
  # completion item, already parsed by Minga.Editing.Completion.parse_item/1),
  # truncated to @doc_byte_cap. Empty string when there is no selected item or it
  # has no docs.
  @spec selected_documentation(EditingCompletion.t()) :: String.t()
  defp selected_documentation(%EditingCompletion{} = comp) do
    case EditingCompletion.selected_item(comp) do
      %{documentation: doc} when is_binary(doc) -> truncate_utf8(doc, @doc_byte_cap)
      _ -> ""
    end
  end

  @spec truncate_utf8(String.t(), non_neg_integer()) :: String.t()
  defp truncate_utf8(text, cap) when byte_size(text) <= cap, do: text

  defp truncate_utf8(text, cap) do
    # Take whole codepoints up to the byte cap; never split a multi-byte char.
    text
    |> binary_part(0, cap)
    |> trim_to_valid_utf8()
  end

  # Drop any trailing bytes that form an incomplete (split) UTF-8 codepoint after
  # a hard byte-length cut, so the result is always valid UTF-8.
  @spec trim_to_valid_utf8(binary()) :: String.t()
  defp trim_to_valid_utf8(bin) when byte_size(bin) == 0, do: ""

  defp trim_to_valid_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_to_valid_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  @spec item_model(EditingCompletion.item()) :: Item.t()
  defp item_model(item) do
    %Item{
      kind: completion_kind(Map.get(item, :kind, :text)),
      label: Map.get(item, :label, ""),
      detail: Map.get(item, :detail, "") || ""
    }
  end

  @spec completion_kind(atom()) :: Item.kind()
  defp completion_kind(kind)
       when kind in [
              :function,
              :method,
              :variable,
              :field,
              :module,
              :keyword,
              :snippet,
              :constant,
              :struct,
              :enum
            ],
       do: kind

  defp completion_kind(_kind), do: :text

  @spec current_cursor_screen_pos(Context.t()) :: {non_neg_integer(), non_neg_integer()}
  defp current_cursor_screen_pos(ctx) do
    active = ctx.windows.active
    layout = ctx.layout

    case {Map.get(layout.window_layouts, active), Map.get(ctx.windows.map, active)} do
      {%{content: {row, col, _w, _h}}, %{content: {:buffer, buf}, viewport: viewport} = window}
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
