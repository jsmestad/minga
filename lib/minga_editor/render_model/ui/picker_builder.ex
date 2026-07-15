defmodule MingaEditor.RenderModel.UI.PickerBuilder do
  @moduledoc false

  import Bitwise

  alias Minga.Buffer
  alias Minga.RenderModel.UI.Picker, as: PickerModel
  alias Minga.RenderModel.UI.Picker.ActionMenu
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.ProjectFileCandidate

  @max_items 100
  @preview_max_lines 50
  @binary_preview_message "Binary file preview unavailable"

  @spec build(Context.t()) :: PickerModel.t()
  def build(ctx) do
    case get_in_modal(ctx) do
      {:picker,
       %{
         picker_ui:
           picker_ui = %{
             picker: picker,
             source: source,
             callback_source: callback_source,
             action_menu: action_menu
           }
       }}
      when picker != nil ->
        mode_prefix = Map.get(picker_ui, :mode_prefix, "")
        load_status = Map.get(picker_ui, :load_status, :ready)
        build_open(ctx, picker, source, callback_source, action_menu, mode_prefix, load_status)

      _ ->
        %PickerModel{}
    end
  end

  @spec get_in_modal(Context.t()) :: term()
  defp get_in_modal(%{shell_state: %{modal: modal}}), do: modal
  defp get_in_modal(_ctx), do: nil

  @spec build_open(
          Context.t(),
          Picker.t(),
          module() | nil,
          MingaEditor.State.Picker.callback_source(),
          term(),
          String.t(),
          PickerModel.load_status()
        ) ::
          PickerModel.t()
  defp build_open(ctx, picker, source, callback_source, action_menu, mode_prefix, load_status) do
    has_preview = source != nil and Picker.Source.gui_preview?(source, callback_source)

    items =
      picker.filtered
      |> Enum.take(@max_items)
      |> enrich_for_display(source, callback_source, picker.query)
      |> Enum.map(&item_model(picker, &1))

    preview_lines = if has_preview, do: build_picker_preview(ctx)

    %PickerModel{
      visible?: true,
      title: picker.title,
      query: picker.query,
      selected_index: picker.selected,
      filtered_count: Enum.count(picker.filtered),
      total_count: Enum.count(picker.items),
      marked_count: Picker.marked_count(picker),
      has_preview?: has_preview,
      items: items,
      action_menu: action_menu_model(action_menu),
      mode_prefix: mode_prefix,
      load_status: load_status,
      preview_lines: preview_lines
    }
  end

  # Builds the deferred display fields (icon, color, two-line description, status
  # annotation) for just the visible window, then recomputes match positions
  # against the enriched label. Sources that already return fully-built items
  # (no `enrich/1`) pass through unchanged. This keeps display derivation in the
  # render model (ruling 4) while filtering stays bounded and lean.
  @spec enrich_for_display(
          [Picker.Item.t()],
          module() | nil,
          MingaEditor.State.Picker.callback_source(),
          String.t()
        ) :: [Picker.Item.t()]
  defp enrich_for_display(items, source, callback_source, query) do
    if source != nil and Picker.Source.enriches?(source) do
      source
      |> Picker.Source.enrich(items, callback_source)
      |> Enum.map(&%{&1 | match_positions: Picker.match_positions(&1.label, query)})
    else
      items
    end
  end

  # Normalize one picker source item into the wire-shaped map the generated
  # `encode_picker_item/1` consumes. All derivation lives here (ruling 4): the
  # `flags` byte, the `icon_color || 0` / `annotation || ""` nil-vs-empty
  # defaulting. (The source `description` is already typed non-nil with a ""
  # default, so it needs no defaulting.) Wire limits are enforced by the adapter,
  # which rejects oversized values without changing this semantic model.
  @spec item_model(Picker.t(), Picker.Item.t()) :: PickerModel.item()
  defp item_model(picker, item) do
    %{
      icon_color: item.icon_color || 0,
      flags: item_flags(item, Picker.marked?(picker, item)),
      label: item.label,
      description: item.description,
      annotation: item.annotation || "",
      match_positions: item.match_positions
    }
  end

  @spec item_flags(Picker.Item.t(), boolean()) :: non_neg_integer()
  defp item_flags(item, marked?) do
    two_line = if item.two_line, do: 1, else: 0
    marked = if marked?, do: 1, else: 0
    bor(two_line, marked <<< 1)
  end

  @spec action_menu_model(term()) :: ActionMenu.t() | nil
  defp action_menu_model(nil), do: nil

  defp action_menu_model({actions, selected}) do
    %ActionMenu{actions: Enum.map(actions, fn {name, _id} -> name end), selected_index: selected}
  end

  # Build preview content for the currently selected picker item.
  @spec build_picker_preview(Context.t()) :: [[PickerModel.preview_segment()]] | nil
  defp build_picker_preview(
         %{
           shell_state: %{
             modal:
               {:picker,
                %{
                  picker_ui: %{
                    picker: picker,
                    source: source,
                    callback_source: callback_source
                  }
                }}
           }
         } = ctx
       ) do
    case Picker.selected_item(picker) do
      nil ->
        nil

      %Picker.Item{} = item ->
        case Picker.Source.preview(source, item, ctx, callback_source) do
          nil -> build_preview_for_item(ctx, item)
          lines -> lines
        end
    end
  end

  # Build preview lines for a file path item.
  @spec build_preview_for_item(Context.t(), Picker.Item.t()) ::
          [[PickerModel.preview_segment()]] | nil
  defp build_preview_for_item(
         ctx,
         %Picker.Item{id: %ProjectFileCandidate{} = candidate}
       ) do
    abs_path =
      case ProjectFileCandidate.resolve(candidate) do
        {:ok, path} -> path
        {:error, _reason} -> nil
      end

    build_file_preview(ctx, abs_path)
  end

  defp build_preview_for_item(ctx, %Picker.Item{id: id}) when is_binary(id) do
    build_file_preview(ctx, resolve_preview_path(id, Minga.Project.resolve_root()))
  end

  defp build_preview_for_item(ctx, %Picker.Item{id: idx}) when is_integer(idx) do
    case Enum.at(ctx.buffers.list, idx) do
      nil -> nil
      buf_pid -> preview_from_buffer(ctx, buf_pid)
    end
  end

  defp build_preview_for_item(_ctx, _id), do: nil

  @spec build_file_preview(Context.t(), String.t() | nil) ::
          [[PickerModel.preview_segment()]] | nil
  defp build_file_preview(_ctx, nil), do: nil

  defp build_file_preview(ctx, abs_path) do
    case find_buffer_for_path(ctx, abs_path) do
      {buf_pid, highlight} when highlight != nil ->
        build_highlighted_preview(buf_pid, highlight, ctx)

      _ ->
        read_file_preview(abs_path, ctx)
    end
  end

  @spec preview_from_buffer(Context.t(), pid()) :: [[PickerModel.preview_segment()]] | nil
  defp preview_from_buffer(ctx, buf_pid) do
    case Map.get(ctx.highlight.highlights, buf_pid) do
      nil ->
        path = safe_file_path(buf_pid)
        if path, do: read_file_preview(path, ctx), else: nil

      highlight ->
        build_highlighted_preview(buf_pid, highlight, ctx)
    end
  end

  @spec find_buffer_for_path(Context.t(), String.t()) ::
          {pid(), MingaEditor.UI.Highlight.t() | nil} | nil
  defp find_buffer_for_path(ctx, abs_path) do
    Enum.find_value(ctx.buffers.list, fn buf_pid ->
      try do
        case Buffer.file_path(buf_pid) do
          ^abs_path ->
            highlight = Map.get(ctx.highlight.highlights, buf_pid)
            {buf_pid, highlight}

          _ ->
            nil
        end
      catch
        :exit, _ -> nil
      end
    end)
  end

  @spec build_highlighted_preview(pid(), MingaEditor.UI.Highlight.t(), Context.t()) ::
          [[PickerModel.preview_segment()]] | nil
  defp build_highlighted_preview(buf_pid, highlight, ctx) do
    content = Buffer.content(buf_pid)
    lines = content |> String.split("\n") |> Enum.take(@preview_max_lines)
    default_fg = Map.get(ctx.theme, :fg, 0xCCCCCC)

    {line_tuples, _} =
      Enum.map_reduce(lines, 0, fn line, offset ->
        {{line, offset}, offset + byte_size(line) + 1}
      end)

    styled_lines = MingaEditor.UI.Highlight.styles_for_visible_lines(highlight, line_tuples)

    Enum.map(styled_lines, fn segments ->
      Enum.map(segments, fn {text, face} ->
        fg = face_to_rgb(face, default_fg)
        bold = face.bold || false
        {text, fg, bold}
      end)
    end)
  catch
    :exit, _ -> nil
  end

  @spec face_to_rgb(Minga.Core.Face.t(), non_neg_integer()) :: non_neg_integer()
  defp face_to_rgb(%{fg: nil}, default), do: default
  defp face_to_rgb(%{fg: fg}, _default) when is_integer(fg), do: fg
  defp face_to_rgb(_, default), do: default

  @spec resolve_preview_path(String.t(), String.t() | nil) :: String.t() | nil
  defp resolve_preview_path(path, root) do
    resolve_preview_path(Path.type(path), path, root)
  end

  @spec resolve_preview_path(
          :absolute | :relative | :volumerelative,
          String.t(),
          String.t() | nil
        ) ::
          String.t() | nil
  defp resolve_preview_path(:absolute, path, _root), do: path
  defp resolve_preview_path(_path_type, _path, nil), do: nil
  defp resolve_preview_path(_path_type, path, root), do: Path.join(root, path)

  @spec read_file_preview(String.t(), Context.t()) :: [[PickerModel.preview_segment()]] | nil
  defp read_file_preview(abs_path, ctx) do
    case File.read(abs_path) do
      {:ok, content} ->
        fg_color = Map.get(ctx.theme, :fg, 0xCCCCCC)

        if text_preview?(content) do
          content
          |> String.split("\n")
          |> Enum.take(@preview_max_lines)
          |> Enum.map(&[{&1, fg_color, false}])
        else
          [[{@binary_preview_message, fg_color, true}]]
        end

      {:error, _} ->
        nil
    end
  end

  @spec text_preview?(binary()) :: boolean()
  defp text_preview?(content) do
    String.valid?(content) and not String.contains?(content, <<0>>)
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(pid) do
    Buffer.file_path(pid)
  catch
    :exit, _ -> nil
  end
end
