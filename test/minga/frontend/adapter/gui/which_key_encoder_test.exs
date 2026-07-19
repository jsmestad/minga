defmodule Minga.Frontend.Adapter.GUI.WhichKeyEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WhichKeyEncoder
  alias Minga.RenderModel.UI.WhichKey

  @op_gui_which_key Minga.Protocol.Opcodes.gui_which_key()

  describe "encode/2" do
    test "encodes hidden which-key" do
      model = %WhichKey{visible: false}
      caches = Caches.new()

      {cmd, _caches} = WhichKeyEncoder.encode(model, caches)

      assert cmd == <<@op_gui_which_key, 0::8>>
    end

    test "encodes visible which-key with exact binding bytes" do
      model = %WhichKey{
        visible: true,
        prefix: "SPC",
        page: 0,
        page_count: 1,
        bindings: [
          %{key: "j", description: "down", kind: :command, icon: nil},
          %{key: "k", description: "up", kind: :group, icon: "folder"}
        ]
      }

      {cmd, _caches} = WhichKeyEncoder.encode(model, Caches.new())

      assert cmd ==
               <<@op_gui_which_key, 1::8, 3::16, "SPC", 0::8, 1::8, 2::16, 0::8, 1::8, "j", 4::16,
                 "down", 0::8, "", 1::8, 1::8, "k", 2::16, "up", 6::8, "folder">>
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

    test "encodes builder-projected bindings directly" do
      node =
        Minga.Keymap.Bindings.new()
        |> Minga.Keymap.Bindings.bind([{?j, 0}], :move_down, "Move down")
        |> Minga.Keymap.Bindings.bind([{?k, 0}], :move_up, "Move up")

      wk_state = %MingaEditor.State.WhichKey{
        show: true,
        node: node,
        prefix_keys: ["SPC"],
        page: 0
      }

      model = MingaEditor.RenderModel.UI.WhichKeyBuilder.build(wk_state)
      {cmd, _caches} = WhichKeyEncoder.encode(model, Caches.new())

      assert cmd ==
               <<@op_gui_which_key, 1::8, 3::16, "SPC", 0::8, 1::8, 2::16, 0::8, 1::8, "j", 9::16,
                 "Move down", 0::8, "", 0::8, 1::8, "k", 7::16, "Move up", 0::8, "">>
    end
  end
end
