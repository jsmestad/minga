defmodule Minga.Frontend.Adapter.GUI.TabBarEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.TabBarEncoder
  alias Minga.RenderModel.UI.TabBar

  @op_gui_tab_bar Minga.Protocol.Opcodes.gui_tab_bar()

  describe "encode/2" do
    test "returns nil when tab bar is suppressed (board mode)" do
      model = %TabBar{encoded: nil, fingerprint: :suppressed}
      caches = Caches.new()

      {cmd, _caches} = TabBarEncoder.encode(model, caches)

      assert cmd == nil
    end

    test "encodes standard tab bar" do
      model = %TabBar{
        encoded: <<@op_gui_tab_bar, 0::8, 1::8, "tab_data">>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd, _caches} = TabBarEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %TabBar{
        encoded: <<@op_gui_tab_bar, 0::8, 1::8>>,
        fingerprint: 42
      }

      caches = Caches.new()

      {cmd1, caches} = TabBarEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = TabBarEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %TabBar{
        encoded: <<@op_gui_tab_bar, 0::8, 1::8>>,
        fingerprint: 42
      }

      model2 = %TabBar{
        encoded: <<@op_gui_tab_bar, 1::8, 2::8, "more">>,
        fingerprint: 99999
      }

      caches = Caches.new()
      {_, caches} = TabBarEncoder.encode(model1, caches)
      {cmd2, _caches} = TabBarEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end

    test "updates cache fingerprint on encode" do
      model = %TabBar{
        encoded: <<@op_gui_tab_bar, 0::8, 1::8>>,
        fingerprint: 42
      }

      caches = Caches.new()
      assert caches.last_tab_bar_fp == nil

      {_cmd, caches} = TabBarEncoder.encode(model, caches)
      assert caches.last_tab_bar_fp == 42
    end
  end
end
