defmodule Minga.Frontend.Adapter.GUI.WhichKeyEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.WhichKey

  @op_gui_which_key Opcodes.gui_which_key()

  @spec encode(WhichKey.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%WhichKey{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_which_key_fp do
      cmd = encode_which_key_binary(model)
      {cmd, %{caches | last_which_key_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_which_key_binary(WhichKey.t()) :: binary()
  defp encode_which_key_binary(%WhichKey{visible: false}) do
    <<@op_gui_which_key, 0::8>>
  end

  defp encode_which_key_binary(%WhichKey{} = model) do
    writer =
      :gui_which_key
      |> Writer.new()
      |> Writer.append(<<@op_gui_which_key, 1::8>>)
      |> Writer.string16(:prefix, model.prefix)
      |> Writer.uint8(:page, model.page)
      |> Writer.uint8(:page_count, model.page_count)
      |> Writer.uint16(:binding_count, Enum.count(model.bindings))

    model.bindings
    |> Enum.reduce(writer, fn binding, acc ->
      kind_byte = if binding.kind == :group, do: 1, else: 0

      acc
      |> Writer.uint8(:binding_kind, kind_byte)
      |> Writer.string8(:binding_key, binding.key)
      |> Writer.string16(:binding_description, binding.description)
      |> Writer.string8(:binding_icon, binding.icon || "")
    end)
    |> Writer.finish()
  end
end
