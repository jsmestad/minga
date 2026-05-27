defmodule Minga.Frontend.Adapter.GUI.SidebarsEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SidebarsEncoder
  alias Minga.RenderModel.UI.Sidebars

  @op_gui_sidebars Minga.Protocol.Opcodes.gui_sidebars()

  describe "encode/2" do
    test "returns nil when encoded is nil" do
      model = %Sidebars{encoded: nil, fingerprint: nil}
      caches = Caches.new()

      {cmd, _caches} = SidebarsEncoder.encode(model, caches)

      assert cmd == nil
    end

    test "encodes sidebars with payload" do
      model = %Sidebars{
        encoded: <<@op_gui_sidebars, 0::32, "sidebar_data">>,
        fingerprint: 12_345
      }

      caches = Caches.new()

      {cmd, _caches} = SidebarsEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %Sidebars{
        encoded: <<@op_gui_sidebars, 5::32, "hello">>,
        fingerprint: 42
      }

      caches = Caches.new()

      {cmd1, caches} = SidebarsEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = SidebarsEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %Sidebars{
        encoded: <<@op_gui_sidebars, 3::32, "abc">>,
        fingerprint: 42
      }

      model2 = %Sidebars{
        encoded: <<@op_gui_sidebars, 5::32, "hello">>,
        fingerprint: 99_999
      }

      caches = Caches.new()
      {_, caches} = SidebarsEncoder.encode(model1, caches)
      {cmd2, _caches} = SidebarsEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end

    test "updates cache fingerprint on encode" do
      model = %Sidebars{
        encoded: <<@op_gui_sidebars, 3::32, "abc">>,
        fingerprint: 42
      }

      caches = Caches.new()
      assert caches.last_sidebars_fp == nil

      {_cmd, caches} = SidebarsEncoder.encode(model, caches)
      assert caches.last_sidebars_fp == 42
    end
  end
end
