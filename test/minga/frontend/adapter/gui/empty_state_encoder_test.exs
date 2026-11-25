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
      focused_id: "recent-1",
      title: "minga",
      path: "~/code/minga",
      status: "main · 2 changed",
      note: "",
      sections: [
        %Section{
          id: :recent,
          title: "Recent",
          empty: "None.",
          items: [
            %Item{
              id: "recent-1",
              kind: :recent_file,
              label: "a.ex",
              detail: "lib",
              meta: "2 h ago",
              jump_key: "1",
              icon: "x",
              icon_color: 0x61AFEF
            }
          ]
        },
        %Section{
          id: :tasks,
          title: "Tasks",
          items: [
            %Item{id: "task-3", kind: :task, label: "Fix", detail: "Needs you", state: :needs_you}
          ]
        }
      ]
    }
  end

  test "encodes the version 2 home payload layout" do
    {cmd, _caches} = EmptyStateEncoder.encode(model(), Caches.new())

    assert <<@op_gui_empty_state, len::16, payload::binary-size(len)>> = cmd

    status = "main · 2 changed"
    status_len = byte_size(status)

    assert <<2::8, 5::16, "minga", 12::16, "~/code/minga", ^status_len::16,
             ^status::binary-size(^status_len), 0::16, 8::8, "recent-1", 2::8, rest::binary>> =
             payload

    # Recent files (1): title, empty line, one row (kind 1) with meta and no state.
    assert <<1::8, 6::8, "Recent", 5::16, "None.", 1::8, 1::8, 8::8, "recent-1", 4::16, "a.ex",
             3::16, "lib", 7::16, "2 h ago", 1::8, "1", 0::8, 1::8, "x", 0x61AFEF::32, 0::8,
             rest::binary>> = rest

    # Minga tasks (5): one task row (kind 5) carrying its state token name.
    assert <<5::8, 5::8, "Tasks", 0::16, 1::8, 5::8, 6::8, "task-3", 3::16, "Fix", 9::16,
             "Needs you", 0::16, 0::8, 0::8, 0::8, 0::32, 9::8, "needs_you">> = rest
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
