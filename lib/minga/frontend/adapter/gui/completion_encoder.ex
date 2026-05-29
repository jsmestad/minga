defmodule Minga.Frontend.Adapter.GUI.CompletionEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.Completion.Item

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

  @spec encode_command(Completion.t()) :: binary()
  def encode_command(%Completion{visible?: false}), do: <<@op_gui_completion, 0::8>>

  def encode_command(%Completion{} = model) do
    entries = Enum.map(model.items, &encode_item/1)

    IO.iodata_to_binary([
      @op_gui_completion,
      <<1::8, model.cursor_row::16, model.cursor_col::16, model.selected_offset::16,
        length(model.items)::16>>
      | entries
    ])
  end

  @spec fingerprint(Completion.t()) :: term()
  defp fingerprint(%Completion{visible?: false}), do: :hidden

  defp fingerprint(%Completion{} = model) do
    {model.visible?, model.cursor_row, model.cursor_col, model.selected_offset, model.items}
  end

  @spec encode_item(Item.t()) :: binary()
  defp encode_item(%Item{} = item) do
    kind_byte = encode_completion_kind(item.kind)
    label = :erlang.iolist_to_binary([item.label])
    detail = :erlang.iolist_to_binary([item.detail || ""])

    <<kind_byte::8, byte_size(label)::16, label::binary, byte_size(detail)::16, detail::binary>>
  end

  @spec encode_completion_kind(atom()) :: non_neg_integer()
  defp encode_completion_kind(:function), do: 1
  defp encode_completion_kind(:method), do: 2
  defp encode_completion_kind(:variable), do: 3
  defp encode_completion_kind(:field), do: 4
  defp encode_completion_kind(:module), do: 5
  defp encode_completion_kind(:keyword), do: 7
  defp encode_completion_kind(:snippet), do: 8
  defp encode_completion_kind(:constant), do: 9
  defp encode_completion_kind(:struct), do: 11
  defp encode_completion_kind(:enum), do: 12
  defp encode_completion_kind(_), do: 0
end
