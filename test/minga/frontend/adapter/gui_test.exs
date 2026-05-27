defmodule Minga.Frontend.Adapter.GUITest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel

  describe "encode_ui/2" do
    test "returns empty commands and unchanged caches for empty UI model" do
      ui = %RenderModel.UI{}
      caches = Caches.new()

      assert {[], ^caches} = GUI.encode_ui(ui, caches)
    end
  end
end
