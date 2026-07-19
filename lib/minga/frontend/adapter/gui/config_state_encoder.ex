defmodule Minga.Frontend.Adapter.GUI.ConfigStateEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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
  # Canonical in-frame 0x97 producer for native settings state decoded directly by frontends.
  @spec encode_command(ConfigState.t()) :: binary()
  def encode_command(%ConfigState{} = model) do
    writer =
      :gui_config_state
      |> Writer.new()
      |> Writer.uint16(:option_count, Enum.count(model.options))

    writer =
      Enum.reduce(model.options, writer, fn {name, value}, acc ->
        encode_option(acc, name, value)
      end)

    writer = Writer.uint16(writer, :theme_preview_count, Enum.count(model.theme_previews))

    writer =
      Enum.reduce(model.theme_previews, writer, fn preview, acc ->
        encode_theme_preview(acc, preview)
      end)

    writer = Writer.uint16(writer, :keybinding_count, Enum.count(model.keybindings))

    writer =
      Enum.reduce(model.keybindings, writer, fn binding, acc ->
        encode_keybinding(acc, binding)
      end)

    payload = Writer.finish(writer)

    :gui_config_state
    |> Writer.new()
    |> Writer.append(<<@op_gui_config_state>>)
    |> Writer.payload16(:payload, payload)
    |> Writer.finish()
  end

  @spec encode_option(Writer.t(), String.t(), ConfigState.value()) :: Writer.t()
  defp encode_option(%Writer{} = writer, name, value) when is_binary(name) do
    writer
    |> Writer.string8(:option_name, name)
    |> encode_value(value)
  end

  @spec encode_value(Writer.t(), ConfigState.value()) :: Writer.t()
  defp encode_value(%Writer{} = writer, value) when is_boolean(value) do
    encoded = if value, do: 1, else: 0

    writer
    |> Writer.append(<<@value_boolean::8>>)
    |> Writer.uint8(:boolean_value, encoded)
  end

  defp encode_value(%Writer{} = writer, value) when is_integer(value) do
    writer
    |> Writer.append(<<@value_integer::8>>)
    |> Writer.int32(:integer_value, value)
  end

  defp encode_value(%Writer{} = writer, value) when is_binary(value) do
    writer
    |> Writer.append(<<@value_string::8>>)
    |> Writer.string16(:string_value, value)
  end

  defp encode_value(%Writer{} = writer, value) when is_atom(value) do
    writer
    |> Writer.append(<<@value_atom::8>>)
    |> Writer.string16(:atom_value, Atom.to_string(value))
  end

  defp encode_value(%Writer{} = writer, value) when is_float(value) do
    Writer.append(writer, <<@value_float::8, value::float-64>>)
  end

  defp encode_value(%Writer{} = writer, value) do
    writer
    |> Writer.append(<<@value_string::8>>)
    |> Writer.string16(:inspected_value, inspect(value))
  end

  @spec encode_theme_preview(Writer.t(), ConfigState.theme_preview()) :: Writer.t()
  defp encode_theme_preview(%Writer{} = writer, %{
         name: name,
         atom: atom,
         editor_bg: bg,
         editor_fg: fg,
         accent: accent
       }) do
    writer
    |> Writer.string8(:theme_name, name)
    |> Writer.string8(:theme_atom, atom)
    |> Writer.rgb24(:theme_editor_bg, bg)
    |> Writer.rgb24(:theme_editor_fg, fg)
    |> Writer.rgb24(:theme_accent, accent)
  end

  @spec encode_keybinding(Writer.t(), ConfigState.keybinding()) :: Writer.t()
  defp encode_keybinding(%Writer{} = writer, %{
         mode: mode,
         key: key,
         command: command,
         description: desc
       }) do
    writer
    |> Writer.string8(:keybinding_mode, mode)
    |> Writer.string16(:keybinding_key, key)
    |> Writer.string16(:keybinding_command, command)
    |> Writer.string16(:keybinding_description, desc)
  end
end
