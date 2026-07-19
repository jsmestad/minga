defmodule Minga.Frontend.Adapter.GUI.ThemeEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.RenderModel.UI.Theme
  alias MingaEditor.RenderModel.UI.ThemeBuilder

  @op_gui_theme 0x74

  describe "encode/2" do
    test "encodes a theme model to correct binary format" do
      model = %Theme{
        name: :test,
        color_slots: [{0x01, 0xFF0000}, {0x02, 0x00FF00}, {0x03, 0x0000FF}]
      }

      caches = Caches.new()
      {cmd, _caches} = ThemeEncoder.encode(model, caches)

      assert <<@op_gui_theme, 3::8, rest::binary>> = cmd
      assert byte_size(rest) == 3 * 4

      # First entry: slot 0x01, R=0xFF, G=0x00, B=0x00
      assert <<0x01, 0xFF, 0x00, 0x00, _rest::binary>> = rest

      # Second entry: slot 0x02, R=0x00, G=0xFF, B=0x00
      <<_first::binary-size(4), 0x02, 0x00, 0xFF, 0x00, _rest::binary>> = rest

      # Third entry: slot 0x03, R=0x00, G=0x00, B=0xFF
      <<_first::binary-size(8), 0x03, 0x00, 0x00, 0xFF>> = rest
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = %Theme{
        name: :test,
        color_slots: [{0x01, 0xFF0000}]
      }

      caches = Caches.new()
      {cmd1, caches} = ThemeEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ThemeEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when model changes" do
      model1 = %Theme{
        name: :theme_a,
        color_slots: [{0x01, 0xFF0000}]
      }

      model2 = %Theme{
        name: :theme_b,
        color_slots: [{0x01, 0x00FF00}]
      }

      caches = Caches.new()
      {cmd1, caches} = ThemeEncoder.encode(model1, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ThemeEncoder.encode(model2, caches)
      assert cmd2 != nil
    end

    test "encodes empty color_slots correctly" do
      model = %Theme{name: :empty, color_slots: []}
      caches = Caches.new()

      {cmd, _caches} = ThemeEncoder.encode(model, caches)
      assert <<@op_gui_theme, 0::8>> = cmd
    end

    test "encodes every built-in theme with all required agent slots" do
      for theme_name <- MingaEditor.UI.Theme.available() do
        editor_theme = MingaEditor.UI.Theme.get!(theme_name)
        model = ThemeBuilder.build(editor_theme)
        {binary, _caches} = ThemeEncoder.encode(model, Caches.new())

        assert_theme_binary(binary, model)

        slots = encoded_slot_map(binary)

        for slot_id <- 0xA0..0xAE do
          assert Map.has_key?(slots, slot_id),
                 "#{theme_name} missing agent slot 0x#{Integer.to_string(slot_id, 16)}"
        end
      end
    end

    test "encodes every doom_one agent field in its canonical slot" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      model = ThemeBuilder.build(theme)
      {binary, _caches} = ThemeEncoder.encode(model, Caches.new())
      slots = encoded_slot_map(binary)

      assert Map.take(slots, Enum.to_list(0xA0..0xAE)) == expected_agent_slots(theme)
      assert Map.fetch!(slots, 0xA7) == {0x51, 0xAF, 0xEF}
    end
  end

  defp assert_theme_binary(binary, %Theme{} = model) do
    assert <<@op_gui_theme, count::8, rest::binary>> = binary
    assert count == length(model.color_slots)
    assert byte_size(rest) == count * 4
    assert rest == expected_slot_bytes(model.color_slots)
  end

  defp expected_slot_bytes(color_slots) do
    color_slots
    |> Enum.map(fn {slot, rgb} ->
      r = Bitwise.bsr(Bitwise.band(rgb, 0xFF0000), 16)
      g = Bitwise.bsr(Bitwise.band(rgb, 0x00FF00), 8)
      b = Bitwise.band(rgb, 0x0000FF)
      <<slot::8, r::8, g::8, b::8>>
    end)
    |> IO.iodata_to_binary()
  end

  defp expected_agent_slots(theme) do
    agent = MingaEditor.UI.Theme.agent_theme(theme)

    [
      agent.panel_bg,
      agent.header_bg,
      agent.header_fg,
      agent.user_border,
      agent.user_label,
      agent.assistant_border,
      agent.assistant_label,
      agent.input_border,
      agent.input_bg,
      agent.input_placeholder,
      agent.text_fg,
      agent.tool_border,
      agent.tool_header,
      agent.code_bg,
      agent.code_border
    ]
    |> Enum.with_index(0xA0)
    |> Map.new(fn {rgb, slot} -> {slot, rgb_tuple(rgb)} end)
  end

  defp rgb_tuple(rgb) do
    {
      Bitwise.bsr(Bitwise.band(rgb, 0xFF0000), 16),
      Bitwise.bsr(Bitwise.band(rgb, 0x00FF00), 8),
      Bitwise.band(rgb, 0x0000FF)
    }
  end

  defp encoded_slot_map(binary) do
    assert <<@op_gui_theme, count::8, rest::binary>> = binary

    rest
    |> parse_slots(count, [])
    |> Map.new()
  end

  defp parse_slots(rest, 0, acc) do
    assert rest == ""
    acc
  end

  defp parse_slots(<<slot::8, r::8, g::8, b::8, rest::binary>>, remaining, acc) do
    parse_slots(rest, remaining - 1, [{slot, {r, g, b}} | acc])
  end
end
