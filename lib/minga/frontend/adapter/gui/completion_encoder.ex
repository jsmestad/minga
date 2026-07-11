defmodule Minga.Frontend.Adapter.GUI.CompletionEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Encode
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Completion

  @op_gui_completion Opcodes.gui_completion()

  @spec encode(Completion.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Completion{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_completion_fp do
      {encode_command(model), %{caches | last_completion_fp: fp}}
    else
      {nil, caches}
    end
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
      items: Enum.map(model.items, fn item -> Map.from_struct(item) end),
      documentation: model.documentation
    }
  end

  @spec fingerprint(Completion.t()) :: term()
  defp fingerprint(%Completion{visible?: false}), do: :hidden

  defp fingerprint(%Completion{} = model) do
    {model.visible?, model.cursor_row, model.cursor_col, model.items, model.documentation}
  end
end
