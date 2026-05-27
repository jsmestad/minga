defmodule Minga.Frontend.Adapter.GUITest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel

  describe "encode_ui/2" do
    test "returns empty commands and unchanged caches for nil theme" do
      ui = %RenderModel.UI{theme: nil}
      caches = Caches.new()

      assert {[], ^caches} = GUI.encode_ui(ui, caches)
    end

    test "encodes theme when present" do
      model = %Minga.RenderModel.UI.Theme{
        name: :test,
        color_slots: [{0x01, 0xFF0000}]
      }

      ui = %RenderModel.UI{theme: model}
      caches = Caches.new()

      assert {[cmd], updated_caches} = GUI.encode_ui(ui, caches)
      assert is_binary(cmd)
      assert <<0x74, _rest::binary>> = cmd
      assert updated_caches.last_theme_fp != nil
    end

    test "skips theme on second call with unchanged model" do
      model = %Minga.RenderModel.UI.Theme{
        name: :test,
        color_slots: [{0x01, 0xFF0000}]
      }

      ui = %RenderModel.UI{theme: model}
      caches = Caches.new()

      {[_cmd], caches} = GUI.encode_ui(ui, caches)
      {cmds, _caches} = GUI.encode_ui(ui, caches)

      assert cmds == []
    end
  end
end
