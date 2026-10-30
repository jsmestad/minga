defmodule Minga.Frontend.Adapter.GUI.FocusOwnerEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.FocusOwnerEncoder
  alias Minga.RenderModel.UI.FocusOwner

  test "encodes every responder and surface in the fixed ten-byte len16 payload" do
    assert Minga.Protocol.Opcodes.protocol_version() >= 30
    responders = [editor_view: 0, picker_query: 1, search_query: 2, inline_edit: 3]

    surfaces = [
      editor: 0,
      file_tree: 1,
      agent: 2,
      git_status: 3,
      conflict: 4,
      inline_edit: 5,
      inline_ask: 6,
      prompt: 7,
      picker: 8,
      completion: 9,
      command_completion: 10,
      search: 11,
      hover_popup: 12,
      empty_state: 13
    ]

    for {responder, responder_byte} <- responders, {surface, surface_byte} <- surfaces do
      owner = %FocusOwner{
        responder: responder,
        surface: surface,
        window_id: 0x12345678,
        generation: 0x9ABCDEF0
      }

      assert {<<0xAA, 10::16, ^responder_byte::8, ^surface_byte::8, 0x12345678::32,
                0x9ABCDEF0::32>>, caches} = FocusOwnerEncoder.encode(owner, Caches.new())

      assert caches.last_focus_owner_fp == :erlang.phash2(owner)
    end
  end

  test "unchanged ownership emits nothing and a fresh keyframe cache re-emits it" do
    owner = %FocusOwner{responder: :editor_view, surface: :editor, window_id: 1}
    {command, caches} = FocusOwnerEncoder.encode(owner, Caches.new())
    assert FocusOwnerEncoder.encode(owner, caches) == {nil, caches}
    assert {^command, _caches} = FocusOwnerEncoder.encode(owner, Caches.new())
  end

  test "every owner identity field invalidates the fingerprint" do
    owner = %FocusOwner{responder: :editor_view, surface: :editor, window_id: 1}
    {_command, caches} = FocusOwnerEncoder.encode(owner, Caches.new())

    for changed <- [
          %{owner | responder: :picker_query},
          %{owner | surface: :prompt},
          %{owner | window_id: 2},
          %{owner | generation: 1}
        ] do
      assert {command, _caches} = FocusOwnerEncoder.encode(changed, caches)
      assert is_binary(command)
    end
  end

  test "window and generation retain full unsigned 32-bit values without truncation" do
    owner = %FocusOwner{
      responder: :editor_view,
      surface: :editor,
      window_id: 0xFFFFFFFF,
      generation: 0xFFFFFFFF
    }

    assert {<<0xAA, 10::16, 0, 0, 0xFFFFFFFF::32, 0xFFFFFFFF::32>>, _caches} =
             FocusOwnerEncoder.encode(owner, Caches.new())

    for field <- [:window_id, :generation], value <- [-1, 0x100000000] do
      invalid = Map.replace!(owner, field, value)
      assert_raise EncodingError, fn -> FocusOwnerEncoder.encode(invalid, Caches.new()) end
    end
  end
end
