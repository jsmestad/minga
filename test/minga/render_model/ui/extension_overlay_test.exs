defmodule Minga.RenderModel.UI.ExtensionOverlayTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ExtensionOverlay
  alias Minga.RenderModel.UI.ExtensionOverlay.Entry

  describe "%ExtensionOverlay{}" do
    test "defaults to no entries" do
      model = %ExtensionOverlay{}

      assert model.entries == []
    end

    test "stores semantic overlay entries" do
      entry = %Entry{
        extension: "demo",
        overlay_id: "cursor",
        window_id: 1,
        row: 2,
        col: 3,
        shape: :cursor,
        fg: 0x51AFEF,
        opacity: 102,
        content: "AI"
      }

      model = %ExtensionOverlay{entries: [entry]}

      assert [%Entry{extension: "demo", shape: :cursor, content: "AI"}] = model.entries
    end
  end
end
