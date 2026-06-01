defmodule MingaEditor.Frontend.GUIEditTimelineTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias Minga.Protocol.Opcodes

  @gui_action_timeline_navigate Opcodes.gui_action_timeline_navigate()

  # Edit timeline encoding now lives in
  # Minga.Frontend.Adapter.GUI.EditTimelineEncoder. This module covers only the
  # timeline-navigate action decoding that still lives in ProtocolGUI.

  describe "decode_gui_action for timeline_navigate" do
    test "decodes navigate to index" do
      assert {:ok, {:timeline_navigate, 3}} ==
               ProtocolGUI.decode_gui_action(@gui_action_timeline_navigate, <<0, 3>>)
    end

    test "decodes navigate to index 0" do
      assert {:ok, {:timeline_navigate, 0}} ==
               ProtocolGUI.decode_gui_action(@gui_action_timeline_navigate, <<0, 0>>)
    end
  end

  describe "full event decode for timeline_navigate" do
    @op_gui_action Opcodes.gui_action()

    test "decodes a complete timeline_navigate event" do
      binary = <<@op_gui_action, @gui_action_timeline_navigate, 0, 5>>

      assert {:ok, {:gui_action, {:timeline_navigate, 5}}} ==
               MingaEditor.Frontend.Protocol.decode_event(binary)
    end
  end
end
