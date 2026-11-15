defmodule Minga.Frontend.Adapter.GUI.AgentHelpEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.AgentHelpEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.RenderModel.UI.AgentHelp

  test "Help carries complete UTF-8 groups independently of a chat frame" do
    model = %AgentHelp{
      visible?: true,
      groups: [{"Review 界", [{"Tab", "Back to chat"}, {"Esc", "Close Help"}]}]
    }

    {command, _caches} = AgentHelpEncoder.encode(model, Caches.new())

    expected =
      <<1, 1, 1, 10::16, "Review 界", 2, 3, "Tab", 12::16, "Back to chat", 3, "Esc", 10::16,
        "Close Help">>

    assert command == <<0xAB, byte_size(expected)::32, expected::binary>>
  end

  test "closing Help emits an explicit hide and unchanged presentation sends nothing" do
    shown = %AgentHelp{visible?: true, groups: []}
    {visible, caches} = AgentHelpEncoder.encode(shown, Caches.new())
    assert visible == <<0xAB, 3::32, 1, 1, 0>>
    assert {nil, ^caches} = AgentHelpEncoder.encode(shown, caches)
    {hidden, caches} = AgentHelpEncoder.encode(%AgentHelp{}, caches)
    assert hidden == <<0xAB, 2::32, 1, 0>>
    assert {nil, ^caches} = AgentHelpEncoder.encode(%AgentHelp{}, caches)
  end

  test "wire bounds reject oversized group counts and UTF-8 key bytes without truncation" do
    for groups <- [
          List.duplicate({"Review", []}, 256),
          [{"Review", [{String.duplicate("界", 86), "Back"}]}]
        ] do
      assert_raise EncodingError, fn ->
        AgentHelpEncoder.encode(%AgentHelp{visible?: true, groups: groups}, Caches.new())
      end
    end
  end
end
