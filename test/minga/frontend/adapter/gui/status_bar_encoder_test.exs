defmodule Minga.Frontend.Adapter.GUI.StatusBarEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.RenderModel.UI.StatusBar

  @op_gui_status_bar Minga.Protocol.Opcodes.gui_status_bar()

  describe "encode/2" do
    test "passes through the pre-encoded binary" do
      encoded = <<@op_gui_status_bar, 2::8, "sections">>
      model = %StatusBar{encoded: encoded}
      caches = Caches.new()

      {cmd, _caches} = StatusBarEncoder.encode(model, caches)

      assert cmd == encoded
    end

    test "always returns a command (no fingerprint caching)" do
      encoded = <<@op_gui_status_bar, 1::8, "data">>
      model = %StatusBar{encoded: encoded}
      caches = Caches.new()

      {cmd1, caches} = StatusBarEncoder.encode(model, caches)
      assert cmd1 == encoded

      {cmd2, _caches} = StatusBarEncoder.encode(model, caches)
      assert cmd2 == encoded
    end
  end
end
