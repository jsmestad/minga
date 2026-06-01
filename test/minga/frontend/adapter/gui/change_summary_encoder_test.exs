defmodule Minga.Frontend.Adapter.GUI.ChangeSummaryEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder
  alias Minga.RenderModel.UI.ChangeSummary
  alias Minga.RenderModel.UI.ChangeSummary.Entry

  @op_gui_change_summary Minga.Protocol.Opcodes.gui_change_summary()

  describe "encode/2 wire format" do
    test "encodes a hidden (empty) summary" do
      {cmd, _caches} = ChangeSummaryEncoder.encode(%ChangeSummary{}, Caches.new())

      # opcode + visible(0) + selected_index(2) + entry_count(2)
      assert cmd == <<@op_gui_change_summary, 0::8, 0::16, 0::16>>
    end

    test "encodes entries with path, action, and line counts" do
      model = %ChangeSummary{
        entries: [
          %Entry{path: "lib/a.ex", action: :modified, lines_added: 3, lines_removed: 1},
          %Entry{path: "x", action: :added, lines_added: 10, lines_removed: 0}
        ],
        selected_index: 1
      }

      {cmd, _caches} = ChangeSummaryEncoder.encode(model, Caches.new())

      expected =
        <<@op_gui_change_summary, 1::8, 1::16, 2::16>> <>
          <<8::16, "lib/a.ex", 0::8, 3::32, 1::32>> <>
          <<1::16, "x", 1::8, 10::32, 0::32>>

      assert cmd == expected
    end

    test "maps each action to its byte" do
      for {action, byte} <- [{:modified, 0}, {:added, 1}, {:deleted, 2}, {:renamed, 3}] do
        model = %ChangeSummary{entries: [%Entry{path: "f", action: action}]}
        {cmd, _} = ChangeSummaryEncoder.encode(model, Caches.new())

        assert <<@op_gui_change_summary, 1::8, 0::16, 1::16, 1::16, "f", ^byte::8, 0::32, 0::32>> =
                 cmd
      end
    end
  end

  describe "encode/2 cache skipping" do
    test "returns nil on the second call with an unchanged model" do
      model = %ChangeSummary{entries: [%Entry{path: "f"}]}

      {cmd1, caches} = ChangeSummaryEncoder.encode(model, Caches.new())
      assert cmd1 != nil

      {cmd2, _caches} = ChangeSummaryEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when the model changes" do
      {_cmd, caches} = ChangeSummaryEncoder.encode(%ChangeSummary{}, Caches.new())

      changed = %ChangeSummary{entries: [%Entry{path: "f", lines_added: 1}]}
      {cmd2, _caches} = ChangeSummaryEncoder.encode(changed, caches)

      assert cmd2 != nil
    end
  end
end
