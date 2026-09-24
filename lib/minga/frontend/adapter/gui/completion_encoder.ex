defmodule Minga.Frontend.Adapter.GUI.CompletionEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Encode
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Completion

  @op_gui_completion Opcodes.gui_completion()
  @op_gui_completion_selection Opcodes.gui_completion_selection()

  @spec encode(Completion.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Completion{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    command =
      case {caches.last_completion_fp, fp} do
        {^fp, ^fp} ->
          nil

        {{:visible, structural, _old_selection}, {:visible, structural, _selection}} ->
          encode_selection_command(model)

        {_previous, _next} ->
          encode_command(model)
      end

    {command, %{caches | last_completion_fp: fp}}
  end

  # The fingerprint/skip-if-unchanged shell stays hand-written here; byte
  # production delegates to the schema-generated pure encoder. The visible/hidden
  # dispatch maps the `Completion` struct to the schema-shaped map the generated
  # `encode_gui_completion/1` consumes (visible flag as 0/1, items as plain
  # field maps).
  @spec encode_command(Completion.t()) :: binary()
  def encode_command(%Completion{} = model) do
    wire = to_wire(model)

    :gui_completion
    |> Writer.new()
    |> Writer.append(<<@op_gui_completion>>)
    |> Writer.append(Encode.encode_gui_completion(wire))
    |> Writer.finish()
  end

  @spec to_wire(Completion.t()) :: map()
  defp to_wire(%Completion{visible?: false}), do: %{visible: 0}

  defp to_wire(%Completion{} = model) do
    %{
      visible: 1,
      cursor_row: model.cursor_row,
      cursor_col: model.cursor_col,
      selected_offset: model.selected_offset,
      selected_item_id: model.selected_item_id,
      items: Enum.map(model.items, &item_to_wire/1),
      documentation: model.documentation,
      total_count: model.total_count,
      matched_count: model.matched_count,
      incomplete: if(model.incomplete?, do: 1, else: 0),
      generation: model.generation
    }
  end

  @spec encode_selection_command(Completion.t()) :: binary()
  defp encode_selection_command(%Completion{} = model) do
    payload =
      :gui_completion_selection
      |> Writer.new()
      |> Writer.uint32(:generation, model.generation)
      |> Writer.string8(:selected_item_id, model.selected_item_id)
      |> Writer.string16(:documentation, model.documentation)
      |> Writer.finish()

    :gui_completion_selection
    |> Writer.new()
    |> Writer.append(<<@op_gui_completion_selection>>)
    |> Writer.payload16(:payload, payload)
    |> Writer.finish()
  end

  @spec item_to_wire(Minga.RenderModel.UI.Completion.Item.t()) :: map()
  defp item_to_wire(item) do
    :gui_completion
    |> Writer.new()
    |> Writer.check_uint8(:match_range_count, Enum.count(item.match_ranges))

    Map.from_struct(item)
  end

  @spec fingerprint(Completion.t()) :: term()
  defp fingerprint(%Completion{visible?: false}), do: :hidden

  defp fingerprint(%Completion{} = model) do
    structural =
      {model.generation, model.visible?, model.cursor_row, model.cursor_col, model.items,
       model.total_count, model.matched_count, model.incomplete?}

    selection = {model.selected_item_id, model.documentation}
    {:visible, structural, selection}
  end
end
