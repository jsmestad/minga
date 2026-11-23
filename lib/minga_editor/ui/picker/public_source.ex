defmodule MingaEditor.UI.Picker.PublicSource do
  @moduledoc false

  alias Minga.Extension.CallbackInvoker
  alias MingaEditor.Extension.Picker.Item, as: PublicItem
  alias MingaEditor.Extension.Picker.Source
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.FilePreview
  alias MingaEditor.UI.Picker.Item

  @type owner :: CallbackInvoker.source()
  @type page :: :done | {:more, cursor :: term()}
  @type preview_result ::
          :none
          | {:file, Path.t(), Source.styled_lines()}
          | {:lines, Source.styled_lines()}
          | {:error, String.t()}

  @spec presentation(owner(), module()) ::
          {:ok, String.t(), boolean(), boolean()} | {:error, String.t()}
  def presentation(owner, module) do
    with {:ok, title} <- invoke(owner, module, :title, [], &text?/1) do
      preview? = function_exported?(module, :preview, 2)
      {:ok, title, preview?, preview? and live_file_preview?(owner, module)}
    end
  end

  @spec fetch(owner(), module(), term(), Source.page_request()) ::
          {:ok, [Item.t()], page()} | {:error, String.t()}
  def fetch(owner, module, args, page_request) do
    case invoke(owner, module, :candidates, [args, page_request], &valid_page?/1) do
      {:ok, {:ok, items, :done}} ->
        {:ok, Enum.map(items, &host_item/1), :done}

      {:ok, {:ok, items, {:more, cursor, presentation}}} ->
        more = to_host_item(presentation, {:extension_more, make_ref()}, %{})
        {:ok, Enum.map(items, &host_item/1) ++ [more], {:more, cursor}}

      {:ok, {:error, message}} ->
        {:error, message}

      {:error, _message} = error ->
        error
    end
  end

  @spec fallback(owner(), module(), String.t(), term()) :: Item.t() | nil
  def fallback(owner, module, query, args) do
    case optional(owner, module, :fallback, [query, args], &(is_nil(&1) or valid_item?(&1)), nil) do
      nil -> nil
      %PublicItem{} = item -> host_item(item)
    end
  end

  @spec preview(owner(), module(), PublicItem.t(), term()) :: preview_result()
  def preview(owner, module, item, args) do
    case invoke(owner, module, :preview, [item, args], &valid_preview?/1) do
      {:ok, {:file, path}} ->
        case FilePreview.read(path) do
          {:ok, lines} -> {:file, path, lines}
          {:error, reason} -> {:error, "File preview unavailable: #{:file.format_error(reason)}"}
        end

      {:ok, preview} ->
        preview

      {:error, _message} = error ->
        error
    end
  end

  @spec actions(owner(), module(), PublicItem.t(), term()) :: [Source.action_entry()]
  def actions(owner, module, item, args) do
    optional(owner, module, :actions, [item, args], &valid_actions?/1, [])
  end

  @spec shortcut_action(owner(), module(), PublicItem.t(), Source.shortcut(), term()) :: term()
  def shortcut_action(owner, module, item, shortcut, args) do
    optional(owner, module, :shortcut_action, [item, shortcut, args], fn _id -> true end, nil)
  end

  @spec on_select(owner(), module(), EditorState.t(), PublicItem.t(), term()) :: EditorState.t()
  def on_select(owner, module, state, item, args) do
    invoke_state(owner, module, :on_select, state, [item, args])
  end

  @spec on_action(owner(), module(), EditorState.t(), term(), PublicItem.t(), term()) ::
          EditorState.t()
  def on_action(owner, module, state, action_id, item, args) do
    invoke_state(owner, module, :on_action, state, [action_id, item, args])
  end

  @spec live_file_preview?(owner(), module()) :: boolean()
  defp live_file_preview?(owner, module) do
    optional(owner, module, :live_file_preview?, [], &is_boolean/1, false)
  end

  @spec optional(owner(), module(), atom(), [term()], (term() -> boolean()), term()) :: term()
  defp optional(owner, module, callback, args, valid?, default) do
    if Code.ensure_loaded?(module) and function_exported?(module, callback, length(args)) do
      case invoke(owner, module, callback, args, valid?) do
        {:ok, value} -> value
        {:error, _message} -> default
      end
    else
      default
    end
  end

  @spec invoke_state(owner(), module(), atom(), EditorState.t(), [term()]) :: EditorState.t()
  defp invoke_state(owner, module, callback, state, args) do
    case invoke(owner, module, callback, [state | args], &is_struct(&1, EditorState)) do
      {:ok, %EditorState{} = new_state} -> new_state
      {:error, message} -> NoticeWorkflow.publish(state, message)
    end
  end

  @spec invoke(owner(), module(), atom(), [term()], (term() -> boolean())) ::
          {:ok, term()} | {:error, String.t()}
  defp invoke(owner, module, callback, args, valid?) do
    case CallbackInvoker.invoke(owner, module, callback, args, :picker_callback) do
      {:ok, value} ->
        if valid?.(value) do
          {:ok, value}
        else
          CallbackInvoker.invalid_return(owner, module, callback, value)
          {:error, "Picker source returned invalid #{callback} data"}
        end

      {:error, _failure} ->
        {:error, "Picker source could not run #{callback}"}
    end
  end

  @spec host_item(PublicItem.t()) :: Item.t()
  defp host_item(%PublicItem{id: id} = item) do
    to_host_item(item, {:extension_item, id}, %{extension_item: item})
  end

  @spec to_host_item(PublicItem.t(), term(), map()) :: Item.t()
  defp to_host_item(item, id, meta) do
    %Item{
      id: id,
      label: if(item.icon in [nil, ""], do: item.label, else: item.icon <> " " <> item.label),
      description: item.description,
      annotation: item.annotation,
      search_text: item.search_text,
      icon_color: item.icon_color,
      meta: meta
    }
  end

  @spec valid_page?(term()) :: boolean()
  defp valid_page?({:ok, items, next}) do
    valid_next?(next) and valid_list?(items, &valid_item?/1)
  end

  defp valid_page?({:error, message}), do: text?(message)
  defp valid_page?(_value), do: false

  @spec valid_next?(term()) :: boolean()
  defp valid_next?(:done), do: true
  defp valid_next?({:more, _cursor, item}), do: valid_item?(item)
  defp valid_next?(_value), do: false

  @spec valid_item?(term()) :: boolean()
  defp valid_item?(%PublicItem{
         id: _id,
         label: label,
         description: description,
         annotation: annotation,
         search_text: search_text,
         icon: icon,
         icon_color: icon_color,
         two_line: two_line
       }) do
    text?(label) and text?(description) and text?(search_text) and
      (is_nil(annotation) or text?(annotation)) and (is_nil(icon) or text?(icon)) and
      (is_nil(icon_color) or rgb?(icon_color)) and is_boolean(two_line)
  end

  defp valid_item?(_value), do: false

  @spec valid_preview?(term()) :: boolean()
  defp valid_preview?(:none), do: true
  defp valid_preview?({:file, path}), do: text?(path) and Path.type(path) == :absolute
  defp valid_preview?({:error, message}), do: text?(message)

  defp valid_preview?({:lines, lines}) do
    valid_list?(lines, fn line -> valid_list?(line, &valid_segment?/1) end)
  end

  defp valid_preview?(_value), do: false

  @spec valid_segment?(term()) :: boolean()
  defp valid_segment?({text, fg, bold?}),
    do: text?(text) and (fg == :default or rgb?(fg)) and is_boolean(bold?)

  defp valid_segment?(_value), do: false

  @spec valid_actions?(term()) :: boolean()
  defp valid_actions?(actions) do
    valid_list?(actions, fn
      {_label, nil} -> false
      {label, _id} -> text?(label)
      _value -> false
    end)
  end

  @spec valid_list?(term(), (term() -> boolean())) :: boolean()
  defp valid_list?([], _valid?), do: true
  defp valid_list?([item | rest], valid?), do: valid?.(item) and valid_list?(rest, valid?)
  defp valid_list?(_not_a_list, _valid?), do: false

  @spec text?(term()) :: boolean()
  defp text?(text), do: is_binary(text) and String.valid?(text)

  @spec rgb?(term()) :: boolean()
  defp rgb?(value), do: is_integer(value) and value in 0..0xFFFFFF
end
