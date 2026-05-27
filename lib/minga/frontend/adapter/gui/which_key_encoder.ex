defmodule Minga.Frontend.Adapter.GUI.WhichKeyEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.WhichKey
  alias Minga.Protocol.Opcodes

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
    prefix_bytes = :erlang.iolist_to_binary([model.prefix])

    entries =
      Enum.map(model.bindings, fn b ->
        kind_byte = if b.kind == :group, do: 1, else: 0
        key = :erlang.iolist_to_binary([b.key])
        desc = :erlang.iolist_to_binary([b.description])
        icon = :erlang.iolist_to_binary([b.icon || ""])

        <<kind_byte::8, byte_size(key)::8, key::binary, byte_size(desc)::16, desc::binary,
          byte_size(icon)::8, icon::binary>>
      end)

    IO.iodata_to_binary([
      @op_gui_which_key,
      <<1::8, byte_size(prefix_bytes)::16, prefix_bytes::binary, model.page::8,
        model.page_count::8, length(model.bindings)::16>>
      | entries
    ])
  end
end
