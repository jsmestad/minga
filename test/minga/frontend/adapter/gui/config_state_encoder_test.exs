defmodule Minga.Frontend.Adapter.GUI.ConfigStateEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ConfigStateEncoder
  alias Minga.RenderModel.UI.ConfigState
  alias MingaEditor.RenderModel.UI.ConfigStateBuilder

  @sample %ConfigState{
    options: [{"wrap", true}, {"tab_width", 4}, {"theme", :astrodark}, {"font_family", "Mono"}],
    theme_previews: [
      %{
        name: "Astrodark",
        atom: "astrodark",
        editor_bg: 0x1A1B26,
        editor_fg: 0xC0CAF5,
        accent: 0x7AA2F7
      }
    ],
    keybindings: [
      %{
        mode: "normal",
        key: "g d",
        command: "lsp_goto_definition",
        description: "Go to definition"
      }
    ]
  }

  describe "encode_command/1" do
    test "encodes the canonical 0x97 envelope from projected settings state" do
      wire = %{
        options: %{wrap: true, tab_width: 4, theme: :astrodark, font_family: "Mono", scale: 1.25},
        theme_previews: @sample.theme_previews,
        keybindings: @sample.keybindings
      }

      encoded = ConfigStateEncoder.encode_command(ConfigStateBuilder.from_wire(wire))

      assert <<0x97, payload_len::16, payload::binary>> = encoded
      assert payload_len == byte_size(payload)
      assert <<5::16, options_payload::binary>> = payload
      {options, after_options} = take_options(options_payload, 5)

      assert options == %{
               "wrap" => true,
               "tab_width" => 4,
               "theme" => :astrodark,
               "font_family" => "Mono",
               "scale" => 1.25
             }

      assert <<1::16, 9, "Astrodark", 9, "astrodark", 0x1A1B26::24, 0xC0CAF5::24, 0x7AA2F7::24,
               1::16, 6, "normal", 3::16, "g d", 19::16, "lsp_goto_definition", 16::16,
               "Go to definition">> = after_options
    end

    test "tags each config value type on the wire" do
      cmd =
        ConfigStateEncoder.encode_command(%ConfigState{
          options: [{"b", true}, {"i", 7}, {"s", "x"}, {"a", :foo}, {"f", 1.25}]
        })

      <<0x97, _len::16, payload::binary>> = cmd
      <<5::16, rest::binary>> = payload

      # boolean: name_len(1) "b" tag(0x01) value(1)
      assert <<1, "b", 0x01, 1, rest::binary>> = rest
      # integer: name_len(1) "i" tag(0x02) value(4 signed)
      assert <<1, "i", 0x02, 7::32-signed, rest::binary>> = rest
      # string: name_len(1) "s" tag(0x03) len(2) bytes
      assert <<1, "s", 0x03, 1::16, "x", rest::binary>> = rest
      # atom: name_len(1) "a" tag(0x04) len(2) bytes
      assert <<1, "a", 0x04, 3::16, "foo", rest::binary>> = rest
      # float: name_len(1) "f" tag(0x05) value(64-bit float). After the options,
      # the payload still carries the (empty) theme-preview and keybinding counts.
      assert <<1, "f", 0x05, 1.25::float-64, 0::16, 0::16>> = rest
    end
  end

  describe "encode/2" do
    test "skips re-emitting an unchanged snapshot" do
      caches = Caches.new()
      {cmd1, caches} = ConfigStateEncoder.encode(@sample, caches)
      assert cmd1 != nil
      {cmd2, _caches} = ConfigStateEncoder.encode(@sample, caches)
      assert cmd2 == nil
    end

    test "re-emits when an option value changes" do
      caches = Caches.new()
      {_cmd1, caches} = ConfigStateEncoder.encode(@sample, caches)
      changed = %{@sample | options: [{"wrap", false} | tl(@sample.options)]}
      {cmd2, _caches} = ConfigStateEncoder.encode(changed, caches)
      assert cmd2 != nil
    end

    test "nil model emits nothing" do
      assert {nil, _caches} = ConfigStateEncoder.encode(nil, Caches.new())
    end
  end

  defp take_options(rest, 0), do: {%{}, rest}

  defp take_options(rest, count) when count > 0 do
    {name, value, rest} = take_option(rest)
    {options, rest} = take_options(rest, count - 1)
    {Map.put(options, name, value), rest}
  end

  defp take_option(<<name_len::8, name::binary-size(name_len), 0x01, value::8, rest::binary>>),
    do: {name, value == 1, rest}

  defp take_option(
         <<name_len::8, name::binary-size(name_len), 0x02, value::32-signed, rest::binary>>
       ),
       do: {name, value, rest}

  defp take_option(
         <<name_len::8, name::binary-size(name_len), 0x03, value_len::16,
           value::binary-size(value_len), rest::binary>>
       ),
       do: {name, value, rest}

  defp take_option(
         <<name_len::8, name::binary-size(name_len), 0x04, value_len::16,
           value::binary-size(value_len), rest::binary>>
       ),
       do: {name, String.to_existing_atom(value), rest}

  defp take_option(
         <<name_len::8, name::binary-size(name_len), 0x05, value::float-64, rest::binary>>
       ),
       do: {name, value, rest}
end
