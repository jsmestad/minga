defmodule Minga.Extension.PanelInteractionTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  describe "decode_gui_action for extension_panel_action" do
    test "decodes a panel action with index context" do
      action_opcode = Minga.Protocol.Opcodes.gui_action_extension_panel_action()
      ext_name = "supervision_lens"
      action_name = "session_selected"

      payload =
        <<byte_size(ext_name)::8, ext_name::binary, byte_size(action_name)::8,
          action_name::binary, 0x01, 2::16>>

      assert {:ok, {:extension_panel_action, ^ext_name, :session_selected, %{index: 2}}} =
               ProtocolGUI.decode_gui_action(action_opcode, payload)
    end

    test "decodes a panel action with node_id context" do
      action_opcode = Minga.Protocol.Opcodes.gui_action_extension_panel_action()
      ext_name = "code_tree"
      action_name = "node_selected"
      node_id = "abc123"

      payload =
        <<byte_size(ext_name)::8, ext_name::binary, byte_size(action_name)::8,
          action_name::binary, 0x02, byte_size(node_id)::8, node_id::binary>>

      assert {:ok, {:extension_panel_action, ^ext_name, :node_selected, %{node_id: ^node_id}}} =
               ProtocolGUI.decode_gui_action(action_opcode, payload)
    end

    test "decodes a panel action with empty context" do
      action_opcode = Minga.Protocol.Opcodes.gui_action_extension_panel_action()
      ext_name = "my_ext"
      action_name = "refresh"

      payload =
        <<byte_size(ext_name)::8, ext_name::binary, byte_size(action_name)::8,
          action_name::binary>>

      assert {:ok, {:extension_panel_action, ^ext_name, :refresh, %{}}} =
               ProtocolGUI.decode_gui_action(action_opcode, payload)
    end

    test "returns error for non-existent atom in action name" do
      action_opcode = Minga.Protocol.Opcodes.gui_action_extension_panel_action()
      ext_name = "my_ext"
      action_name = "this_atom_definitely_does_not_exist_#{System.unique_integer()}"

      payload =
        <<byte_size(ext_name)::8, ext_name::binary, byte_size(action_name)::8,
          action_name::binary>>

      assert :error = ProtocolGUI.decode_gui_action(action_opcode, payload)
    end
  end
end
