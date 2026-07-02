defmodule Minga.Frontend.Adapter.GUI.EmptyStateEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EmptyStateEncoder
  alias Minga.RenderModel.UI.EmptyState
  alias Minga.RenderModel.UI.EmptyState.Item
  alias Minga.RenderModel.UI.EmptyState.Section

  @op_gui_empty_state Minga.Protocol.Opcodes.gui_empty_state()

  defp model do
    %EmptyState{
      visible?: true,
      crashed?: true,
      focused_id: "resume",
      version: "v0.9",
      sections: [
        %Section{
          id: :session,
          title: "Crashed session",
          items: [
            %Item{
              id: "resume",
              kind: :resume,
              label: "restore session",
              detail: "4 files",
              jump_key: "r"
            }
          ]
        },
        %Section{
          id: :start,
          title: "Start",
          items: [
            %Item{
              id: "action-find-file",
              kind: :action,
              label: "open file",
              chord: "SPC f f",
              icon: "x",
              icon_color: 0x61AFEF
            }
          ]
        }
      ]
    }
  end

  test "encodes the visible payload layout" do
    {cmd, _caches} = EmptyStateEncoder.encode(model(), Caches.new())

    assert <<@op_gui_empty_state, len::16, payload::binary-size(len)>> = cmd

    assert <<1::8, flags::8, 4::8, "v0.9", 6::8, "resume", 2::8, rest::binary>> = payload
    assert Bitwise.band(flags, 0x01) == 0x01

    # First section: session (0), title, one resume item (kind 0).
    assert <<0::8, 15::8, "Crashed session", 1::8, 0::8, 6::8, "resume", label_len::16,
             rest::binary>> = rest

    assert <<"restore session", detail_len::16, "4 files", 1::8, "r", 0::8, 0::8, 0::32,
             rest::binary>> = rest

    assert label_len == byte_size("restore session")
    assert detail_len == byte_size("4 files")

    # Second section: start (2), one action item (kind 2) with a chord.
    assert <<2::8, 5::8, "Start", 1::8, 2::8, 16::8, "action-find-file", 9::16, "open file",
             0::16, 0::8, 7::8, "SPC f f", 1::8, "x", 0x61AFEF::32>> = rest
  end

  test "hidden state encodes a single visible=0 byte" do
    {cmd, _caches} = EmptyStateEncoder.encode(%EmptyState{visible?: false}, Caches.new())

    assert cmd == <<@op_gui_empty_state, 1::16, 0::8>>
  end

  test "nil model encodes as hidden" do
    {cmd, _caches} = EmptyStateEncoder.encode(nil, Caches.new())

    assert <<@op_gui_empty_state, 1::16, 0::8>> = cmd
  end

  test "fingerprint caching suppresses identical frames and re-emits on change" do
    {cmd1, caches} = EmptyStateEncoder.encode(model(), Caches.new())
    {cmd2, caches} = EmptyStateEncoder.encode(model(), caches)
    {cmd3, _caches} = EmptyStateEncoder.encode(%EmptyState{visible?: false}, caches)

    assert cmd1 != nil
    assert cmd2 == nil
    assert cmd3 == <<@op_gui_empty_state, 1::16, 0::8>>
  end
end
