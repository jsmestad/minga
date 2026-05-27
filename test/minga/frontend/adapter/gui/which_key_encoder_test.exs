defmodule Minga.Frontend.Adapter.GUI.WhichKeyEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WhichKeyEncoder
  alias Minga.RenderModel.UI.WhichKey
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_which_key Minga.Protocol.Opcodes.gui_which_key()

  describe "encode/2" do
    test "encodes hidden which-key" do
      model = %WhichKey{visible: false}
      caches = Caches.new()

      {cmd, _caches} = WhichKeyEncoder.encode(model, caches)

      assert <<@op_gui_which_key, 0::8>> = cmd
    end

    test "encodes visible which-key with bindings" do
      model = %WhichKey{
        visible: true,
        prefix: "SPC",
        page: 0,
        page_count: 1,
        bindings: [
          %{key: "j", description: "down", kind: :command, icon: nil},
          %{key: "k", description: "up", kind: :command, icon: nil}
        ]
      }

      caches = Caches.new()
      {cmd, _caches} = WhichKeyEncoder.encode(model, caches)

      assert <<@op_gui_which_key, 1::8, _rest::binary>> = cmd
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = %WhichKey{visible: false}
      caches = Caches.new()

      {cmd1, caches} = WhichKeyEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = WhichKeyEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when model changes" do
      model1 = %WhichKey{visible: false}
      model2 = %WhichKey{
        visible: true,
        prefix: "SPC",
        page: 0,
        page_count: 1,
        bindings: [%{key: "a", description: "action", kind: :command, icon: nil}]
      }

      caches = Caches.new()
      {_, caches} = WhichKeyEncoder.encode(model1, caches)
      {cmd2, _caches} = WhichKeyEncoder.encode(model2, caches)

      assert cmd2 != nil
    end

    test "produces byte-identical output to legacy ProtocolGUI for hidden state" do
      legacy_binary = ProtocolGUI.encode_gui_which_key(%{show: false})

      model = %WhichKey{visible: false}
      caches = Caches.new()
      {new_binary, _caches} = WhichKeyEncoder.encode(model, caches)

      assert new_binary == legacy_binary
    end

    test "produces byte-identical output to legacy ProtocolGUI for show=true, node=nil" do
      legacy_binary = ProtocolGUI.encode_gui_which_key(%{show: true, node: nil})

      model = %WhichKey{visible: false}
      caches = Caches.new()
      {new_binary, _caches} = WhichKeyEncoder.encode(model, caches)

      assert new_binary == legacy_binary
    end

    test "produces byte-identical output to legacy ProtocolGUI with real bindings" do
      # Build a real keymap node (bind/4 takes root, keys, command, description)
      node = Minga.Keymap.Bindings.new()
      node = Minga.Keymap.Bindings.bind(node, [{?j, 0}], :move_down, "Move down")
      node = Minga.Keymap.Bindings.bind(node, [{?k, 0}], :move_up, "Move up")

      wk_state = %MingaEditor.State.WhichKey{
        show: true,
        node: node,
        prefix_keys: ["SPC"],
        page: 0
      }

      legacy_binary = ProtocolGUI.encode_gui_which_key(wk_state)

      model = MingaEditor.RenderModel.UI.WhichKeyBuilder.build(wk_state)
      caches = Caches.new()
      {new_binary, _caches} = WhichKeyEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "WhichKey encoder output does not match legacy output"
    end
  end
end
