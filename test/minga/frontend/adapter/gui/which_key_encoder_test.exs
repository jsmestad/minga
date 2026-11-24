defmodule Minga.Frontend.Adapter.GUI.WhichKeyEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WhichKeyEncoder
  alias Minga.RenderModel.UI.WhichKey

  @op_gui_which_key Minga.Protocol.Opcodes.gui_which_key()

  defp visible_model do
    %WhichKey{
      visible: true,
      path: "SPC a",
      breadcrumb: [
        %{key: "SPC", label: "", path: "SPC"},
        %{key: "a", label: "Minga", path: "SPC a"}
      ],
      count: "· 1",
      hints: [%{key: "⌫", label: "back"}],
      entries: [
        %{
          key: "s",
          codepoint: ?s,
          modifiers: 0,
          label: "Stop",
          kind: :command,
          section: "Tasks",
          count: "",
          platform_key: "⌘."
        },
        %{
          key: "q",
          codepoint: ?q,
          modifiers: 0,
          label: "Queue ›",
          kind: :group,
          section: "",
          count: "· 2",
          platform_key: ""
        }
      ]
    }
  end

  test "a hidden panel is the opcode and a zero byte" do
    assert {<<@op_gui_which_key, 0::8>>, _caches} =
             WhichKeyEncoder.encode(%WhichKey{visible: false}, Caches.new())
  end

  test "a visible panel encodes path, breadcrumb, count, hints and entries in order" do
    {cmd, _caches} = WhichKeyEncoder.encode(visible_model(), Caches.new())

    count = "· 1"
    back = "⌫"
    cmd_dot = "⌘."
    two = "· 2"

    assert cmd ==
             <<@op_gui_which_key, 1::8, 5::16, "SPC a", 2::8, 3::8, "SPC", 0::16, 3::16, "SPC",
               1::8, "a", 5::16, "Minga", 5::16, "SPC a", byte_size(count)::16, count::binary,
               1::8, byte_size(back)::8, back::binary, 4::16, "back", 2::16, 0::8, 1::8, "s",
               ?s::32, 0::8, 4::16, "Stop", 5::16, "Tasks", 0::16, byte_size(cmd_dot)::8,
               cmd_dot::binary, 1::8, 1::8, "q", ?q::32, 0::8, byte_size("Queue ›")::16,
               "Queue ›", 0::16, byte_size(two)::16, two::binary, 0::8>>
  end

  test "an unchanged model is not re-sent; a changed count is" do
    {first, caches} = WhichKeyEncoder.encode(visible_model(), Caches.new())
    assert first != nil
    assert {nil, caches} = WhichKeyEncoder.encode(visible_model(), caches)

    changed = %{visible_model() | count: "· 2"}
    assert {resent, _caches} = WhichKeyEncoder.encode(changed, caches)
    assert resent != nil
  end
end
