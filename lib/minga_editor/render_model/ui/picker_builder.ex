defmodule MingaEditor.RenderModel.UI.PickerBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.RenderModel.UI.Picker, as: PickerModel
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.UI.Picker

  @max_items 100

  @spec build(Context.t()) :: PickerModel.t()
  def build(ctx) do
    case get_in_modal(ctx) do
      {:picker,
       %{picker_ui: picker_ui = %{picker: picker, source: source, action_menu: action_menu}}}
      when picker != nil ->
        mode_prefix = Map.get(picker_ui, :mode_prefix, "")
        load_status = Map.get(picker_ui, :load_status, :ready)
        build_open(ctx, picker, source, action_menu, mode_prefix, load_status)

      _ ->
        build_closed()
    end
  end

  @spec get_in_modal(Context.t()) :: term()
  defp get_in_modal(%{shell_state: %{modal: modal}}), do: modal
  defp get_in_modal(_ctx), do: nil

  @spec build_open(Context.t(), Picker.t(), module() | nil, term(), String.t(), atom()) ::
          PickerModel.t()
  defp build_open(ctx, picker, source, action_menu, mode_prefix, load_status) do
    has_preview = source != nil and Picker.Source.gui_preview?(source)

    fp =
      picker_fingerprint(picker, has_preview, action_menu, mode_prefix, @max_items, load_status)

    preview_lines = if has_preview, do: build_picker_preview(ctx)

    picker_cmd =
      ProtocolGUI.encode_gui_picker(
        picker,
        has_preview,
        action_menu,
        @max_items,
        mode_prefix,
        load_status
      )

    preview_cmd = ProtocolGUI.encode_gui_picker_preview(preview_lines)
    encoded = IO.iodata_to_binary([picker_cmd, preview_cmd])

    %PickerModel{encoded: encoded, fingerprint: fp}
  end

  @spec build_closed() :: PickerModel.t()
  defp build_closed do
    picker_cmd = ProtocolGUI.encode_gui_picker(nil)
    preview_cmd = ProtocolGUI.encode_gui_picker_preview(nil)
    encoded = IO.iodata_to_binary([picker_cmd, preview_cmd])

    %PickerModel{encoded: encoded, fingerprint: :closed}
  end

  @spec picker_fingerprint(
          Picker.t(),
          boolean(),
          term(),
          String.t(),
          non_neg_integer(),
          atom()
        ) ::
          integer()
  defp picker_fingerprint(picker, has_preview, action_menu, mode_prefix, max_items, load_status) do
    limit = max_items

    visible_items =
      picker.filtered
      |> Enum.take(limit)
      |> Enum.map(fn item ->
        {item.id, item.label, item.description, item.annotation, item.search_text,
         item.icon_color, item.two_line, item.match_positions, Picker.marked?(picker, item)}
      end)

    :erlang.phash2({
      picker.title,
      picker.query,
      mode_prefix,
      picker.selected,
      length(picker.filtered),
      length(picker.items),
      Picker.marked_count(picker),
      has_preview,
      visible_items,
      action_menu,
      load_status
    })
  end

  # Build preview content for the currently selected picker item.
  @spec build_picker_preview(Context.t()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp build_picker_preview(
         %{shell_state: %{modal: {:picker, %{picker_ui: %{picker: picker, source: source}}}}} =
           ctx
       ) do
    case Picker.selected_item(picker) do
      nil ->
        nil

      %Picker.Item{id: id} = item ->
        case Picker.Source.preview(source, item, ctx) do
          nil -> build_preview_for_item(ctx, id)
          lines -> lines
        end
    end
  end

  @preview_max_lines 50

  # Build preview lines for a file path item.
  @spec build_preview_for_item(Context.t(), term()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp build_preview_for_item(ctx, id) when is_binary(id) do
    abs_path = resolve_preview_path(id)

    case find_buffer_for_path(ctx, abs_path) do
      {buf_pid, highlight} when highlight != nil ->
        build_highlighted_preview(buf_pid, highlight, ctx)

      _ ->
        read_file_preview(abs_path, ctx)
    end
  end

  defp build_preview_for_item(ctx, idx) when is_integer(idx) do
    case Enum.at(ctx.buffers.list, idx) do
      nil -> nil
      buf_pid -> preview_from_buffer(ctx, buf_pid)
    end
  end

  defp build_preview_for_item(_ctx, _id), do: nil

  @spec preview_from_buffer(Context.t(), pid()) :: [[ProtocolGUI.preview_segment()]] | nil
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
          [[ProtocolGUI.preview_segment()]] | nil
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

  @spec resolve_preview_path(String.t()) :: String.t()
  defp resolve_preview_path(path) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.join(Minga.Project.resolve_root(), path)
    end
  end

  @spec read_file_preview(String.t(), Context.t()) :: [[ProtocolGUI.preview_segment()]] | nil
  defp read_file_preview(abs_path, ctx) do
    case File.read(abs_path) do
      {:ok, content} ->
        fg_color = Map.get(ctx.theme, :fg, 0xCCCCCC)

        content
        |> String.split("\n")
        |> Enum.take(@preview_max_lines)
        |> Enum.map(&[{&1, fg_color, false}])

      {:error, _} ->
        nil
    end
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(pid) do
    Buffer.file_path(pid)
  catch
    :exit, _ -> nil
  end
end
