defmodule Minga.Frontend.Adapter.GUI.ConfigStateEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.ConfigState

  @op_gui_config_state Opcodes.gui_config_state()

  # Config value type tags. Must match the decoder in
  # MingaEditor.Frontend.Protocol.GUI and the frontend decoders.
  @value_boolean 0x01
  @value_integer 0x02
  @value_string 0x03
  @value_atom 0x04
  @value_float 0x05

  @spec encode(ConfigState.t() | nil, Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(nil, %Caches{} = caches), do: {nil, caches}

  def encode(%ConfigState{} = model, %Caches{} = caches) do
    fp = :erlang.phash2({model.options, model.theme_previews, model.keybindings})

    if fp != caches.last_config_state_fp do
      {encode_command(model), %{caches | last_config_state_fp: fp}}
    else
      {nil, caches}
    end
  end

  # Forward-compatible 0x97 envelope: opcode(1) + payload_length(2) + payload.
  # The payload is byte-identical to the legacy ProtocolGUI.encode_gui_config_state
  # so frontends decode it unchanged.
  @spec encode_command(ConfigState.t()) :: binary()
  def encode_command(%ConfigState{} = model) do
    option_entries = Enum.map(model.options, fn {name, value} -> encode_option(name, value) end)
    preview_entries = Enum.map(model.theme_previews, &encode_theme_preview/1)
    binding_entries = Enum.map(model.keybindings, &encode_keybinding/1)

    payload =
      IO.iodata_to_binary([
        <<length(option_entries)::16>>,
        option_entries,
        <<length(preview_entries)::16>>,
        preview_entries,
        <<length(binding_entries)::16>>,
        binding_entries
      ])

    <<@op_gui_config_state, byte_size(payload)::16, payload::binary>>
  end

  @spec encode_option(String.t(), ConfigState.value()) :: binary()
  defp encode_option(name, value) when is_binary(name) do
    name_bytes = :erlang.iolist_to_binary([name])
    value_payload = encode_value(value)
    <<byte_size(name_bytes)::8, name_bytes::binary, value_payload::binary>>
  end

  @spec encode_value(ConfigState.value()) :: binary()
  defp encode_value(value) when is_boolean(value) do
    encoded = if value, do: 1, else: 0
    <<@value_boolean::8, encoded::8>>
  end

  defp encode_value(value) when is_integer(value),
    do: <<@value_integer::8, value::32-signed>>

  defp encode_value(value) when is_binary(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<@value_string::8, byte_size(bytes)::16, bytes::binary>>
  end

  defp encode_value(value) when is_atom(value) do
    bytes = Atom.to_string(value)
    <<@value_atom::8, byte_size(bytes)::16, bytes::binary>>
  end

  defp encode_value(value) when is_float(value), do: <<@value_float::8, value::float-64>>

  defp encode_value(value) do
    bytes = inspect(value)
    <<@value_string::8, byte_size(bytes)::16, bytes::binary>>
  end

  @spec encode_theme_preview(ConfigState.theme_preview()) :: binary()
  defp encode_theme_preview(%{
         name: name,
         atom: atom,
         editor_bg: bg,
         editor_fg: fg,
         accent: accent
       }) do
    <<string8(name)::binary, string8(atom)::binary, bg::24, fg::24, accent::24>>
  end

  @spec encode_keybinding(ConfigState.keybinding()) :: binary()
  defp encode_keybinding(%{mode: mode, key: key, command: command, description: desc}) do
    <<string8(mode)::binary, string16(key)::binary, string16(command)::binary,
      string16(desc)::binary>>
  end

  @spec string8(String.t()) :: binary()
  defp string8(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<byte_size(bytes)::8, bytes::binary>>
  end

  @spec string16(String.t()) :: binary()
  defp string16(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<byte_size(bytes)::16, bytes::binary>>
  end
end
