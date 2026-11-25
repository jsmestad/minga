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
    :gui_which_key
    |> Writer.new()
    |> Writer.append(<<@op_gui_which_key, 1::8>>)
    |> Writer.string16(:path, model.path)
    |> Writer.uint8(:crumb_count, Enum.count(model.breadcrumb))
    |> encode_each(model.breadcrumb, fn crumb, acc ->
      acc
      |> Writer.string8(:crumb_key, crumb.key)
      |> Writer.string16(:crumb_label, crumb.label)
      |> Writer.string16(:crumb_path, crumb.path)
    end)
    |> Writer.string16(:count, model.count.text)
    |> Writer.uint8(:count_tone, tone_byte(model.count.tone))
    |> Writer.uint8(:hint_count, Enum.count(model.hints))
    |> encode_each(model.hints, fn hint, acc ->
      acc |> Writer.string8(:hint_key, hint.key) |> Writer.string16(:hint_label, hint.label)
    end)
    |> Writer.uint16(:entry_count, Enum.count(model.entries))
    |> encode_each(model.entries, fn entry, acc ->
      acc
      |> Writer.uint8(:entry_kind, kind_byte(entry.kind))
      |> Writer.string8(:entry_key, entry.key)
      |> Writer.uint32(:entry_codepoint, entry.codepoint)
      |> Writer.uint8(:entry_modifiers, entry.modifiers)
      |> Writer.string16(:entry_label, entry.label)
      |> Writer.string16(:entry_section, entry.section)
      |> Writer.string16(:entry_count, entry.count.text)
      |> Writer.uint8(:entry_count_tone, tone_byte(entry.count.tone))
      |> Writer.string8(:entry_platform_key, entry.platform_key)
    end)
    |> Writer.finish()
  end

  @spec encode_each(Writer.t(), [term()], (term(), Writer.t() -> Writer.t())) :: Writer.t()
  defp encode_each(writer, items, fun), do: Enum.reduce(items, writer, fun)

  @spec tone_byte(WhichKey.tone()) :: 0 | 1 | 2
  defp tone_byte(:muted), do: 0
  defp tone_byte(:needs_you), do: 1
  defp tone_byte(:error), do: 2

  @spec kind_byte(WhichKey.kind()) :: 0 | 1
  defp kind_byte(:group), do: 1
  defp kind_byte(:command), do: 0
end
