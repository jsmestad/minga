defmodule MingaEditor.Frontend.FileDialogProtocolTest do
  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI

  test "encodes correlated Open and Save As requests" do
    assert <<opcode, 7::16, 42::32, 0, 0::16>> = Protocol.encode_gui_request(42, :open)
    assert opcode == Opcodes.gui_request()

    path = "/tmp/example.txt"

    assert <<^opcode, payload_length::16, 43::32, 1, path_length::16, ^path::binary>> =
             Protocol.encode_gui_request(43, :save_as, path)

    assert payload_length == 7 + byte_size(path)
    assert path_length == byte_size(path)
  end

  test "decodes cancel, multi-open, and Save As results" do
    action = Opcodes.gui_action_file_dialog_result()

    assert {:ok, {:file_dialog_result, 7, :cancel}} =
             GUI.decode_gui_action(action, <<7::32, 0, 0::16>>)

    open_payload = <<7::32, 1, 2::16, 6::16, "/a.txt", 6::16, "/b.txt">>

    assert {:ok, {:file_dialog_result, 7, {:open, ["/a.txt", "/b.txt"]}}} =
             GUI.decode_gui_action(action, open_payload)

    save_payload = <<8::32, 2, 1::16, 8::16, "/new.txt">>

    assert {:ok, {:file_dialog_result, 8, {:save_as, "/new.txt"}}} =
             GUI.decode_gui_action(action, save_payload)
  end

  test "rejects malformed and mismatched file-dialog results" do
    action = Opcodes.gui_action_file_dialog_result()

    for payload <- [
          <<1::32, 0, 1::16, 0::16>>,
          <<1::32, 1, 0::16>>,
          <<1::32, 1, 1::16, 9::16, "short">>,
          <<1::32, 2, 2::16, 1::16, "a", 1::16, "b">>,
          <<1::32, 3, 0::16>>
        ] do
      assert :error = GUI.decode_gui_action(action, payload)
    end
  end
end
