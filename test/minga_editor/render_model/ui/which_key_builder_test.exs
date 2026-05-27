defmodule MingaEditor.RenderModel.UI.WhichKeyBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.WhichKeyBuilder
  alias Minga.RenderModel.UI.WhichKey
  alias MingaEditor.State.WhichKey, as: WhichKeyState

  describe "build/1" do
    test "returns hidden model when show is false" do
      wk = %WhichKeyState{show: false}
      model = WhichKeyBuilder.build(wk)

      assert %WhichKey{} = model
      assert model.visible == false
      assert model.bindings == []
    end

    test "returns hidden model when show is true but node is nil" do
      wk = %WhichKeyState{show: true, node: nil}
      model = WhichKeyBuilder.build(wk)

      assert %WhichKey{} = model
      assert model.visible == false
    end

    test "returns visible model with bindings when node is present" do
      # Build a real keymap node for testing (bind/4 takes root, keys, command, description)
      node = Minga.Keymap.Bindings.new()
      node = Minga.Keymap.Bindings.bind(node, [{?j, 0}], :move_down, "Move down")
      node = Minga.Keymap.Bindings.bind(node, [{?k, 0}], :move_up, "Move up")

      wk = %WhichKeyState{show: true, node: node, prefix_keys: ["SPC"], page: 0}
      model = WhichKeyBuilder.build(wk)

      assert %WhichKey{} = model
      assert model.visible == true
      assert model.prefix == "SPC"
      assert model.page == 0
      assert model.page_count >= 1
      assert length(model.bindings) == 2

      Enum.each(model.bindings, fn b ->
        assert is_binary(b.key)
        assert is_binary(b.description)
        assert b.kind in [:command, :group]
      end)
    end

    test "prefix is joined with spaces" do
      node = Minga.Keymap.Bindings.new()
      node = Minga.Keymap.Bindings.bind(node, [{?a, 0}], :action, "action")

      wk = %WhichKeyState{show: true, node: node, prefix_keys: ["SPC", "g"], page: 0}
      model = WhichKeyBuilder.build(wk)

      assert model.prefix == "SPC g"
    end
  end
end
