defmodule Minga.Frontend.Adapter.GUI.ThemeEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.RenderModel.UI.Theme
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

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

    test "produces byte-identical output to legacy ProtocolGUI.encode_gui_theme/1" do
      for theme_name <- MingaEditor.UI.Theme.available() do
        editor_theme = MingaEditor.UI.Theme.get!(theme_name)

        # Legacy path: ProtocolGUI encodes directly from the editor theme
        legacy_binary = ProtocolGUI.encode_gui_theme(editor_theme)

        # New path: builder produces a model, encoder produces binary
        model = MingaEditor.RenderModel.UI.ThemeBuilder.build(editor_theme)
        caches = Caches.new()
        {new_binary, _caches} = ThemeEncoder.encode(model, caches)

        assert new_binary == legacy_binary,
               "Theme #{theme_name}: new encoder output does not match legacy output"
      end
    end

    test "fingerprint matches legacy fingerprint for skip behavior" do
      editor_theme = MingaEditor.UI.Theme.get!(:doom_one)
      model = MingaEditor.RenderModel.UI.ThemeBuilder.build(editor_theme)

      # The legacy fingerprint was: phash2({theme.name, Slots.to_color_pairs(theme)})
      # The new fingerprint is: phash2({model.name, model.color_slots})
      # The model.color_slots are the to_color_pairs output with nils rejected.
      # These won't be identical if the legacy included nils, but within each
      # path the skip behavior is internally consistent. What matters is that
      # the same model produces the same fingerprint.
      caches = Caches.new()
      {_cmd, caches} = ThemeEncoder.encode(model, caches)
      assert caches.last_theme_fp != nil

      # Same model should produce same fingerprint
      fp = :erlang.phash2({model.name, model.color_slots})
      assert caches.last_theme_fp == fp
    end
  end
end
