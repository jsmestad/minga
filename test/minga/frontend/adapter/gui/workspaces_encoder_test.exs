defmodule Minga.Frontend.Adapter.GUI.WorkspacesEncoderTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Frontend.Adapter.GUI.WorkspacesEncoder
  alias Minga.RenderModel.UI.Workspaces
  alias Minga.RenderModel.UI.Workspaces.VisibleTab
  alias Minga.RenderModel.UI.Workspaces.Workspace

  @op_gui_workspaces Minga.Protocol.Opcodes.gui_workspaces()

  describe "encode/2" do
    test "returns nil when workspaces are hidden" do
      assert {nil, _caches} = WorkspacesEncoder.encode(%Workspaces{}, Caches.new())
    end

    test "encodes full v2 workspace and visible tab command directly" do
      model = full_model()

      {cmd, _caches} = WorkspacesEncoder.encode(model, Caches.new())

      assert <<@op_gui_workspaces, len::16, payload::binary-size(len)>> = cmd
      assert <<2::8, 2::16, 1::8, 1::8, 2::8, rest::binary>> = payload

      {manual_workspace, rest} = decode_workspace(rest)

      assert manual_workspace == %{
               id: 1,
               kind: 0,
               status: 0,
               flags: 0,
               color: 0,
               tab_count: 1,
               draft_count: 0,
               conflict_count: 0,
               running_background_count: 0,
               label: "Files",
               icon: "folder"
             }

      {agent_workspace, rest} = decode_workspace(rest)

      assert agent_workspace == %{
               id: 2,
               kind: 1,
               status: 2,
               flags: 0x03,
               color: 0x123456,
               tab_count: 3,
               draft_count: 4,
               conflict_count: 5,
               running_background_count: 6,
               label: "Agent",
               icon: "robot"
             }

      assert <<3::16, rest::binary>> = rest
      {file_tab, rest} = decode_visible_tab(rest)

      assert file_tab == %{
               id: 7,
               workspace_id: 2,
               kind: 0,
               flags: 0x33,
               path_hash: Wire.path_hash("/project/README.md"),
               icon: "󰈙",
               label: "README.md",
               path: "/project/README.md",
               tint: 0x654321
             }

      {agent_tab, rest} = decode_visible_tab(rest)

      assert agent_tab == %{
               id: 8,
               workspace_id: 2,
               kind: 1,
               flags: 0,
               path_hash: 0,
               icon: "cpu",
               label: "Agent",
               path: "",
               tint: 0
             }

      {ephemeral_tab, ""} = decode_visible_tab(rest)
      assert ephemeral_tab.id == 9
      assert ephemeral_tab.path == ""
      assert band(ephemeral_tab.flags, 0x40) == 0x40
    end

    test "returns nil on second call with same semantic data" do
      model = %Workspaces{
        visible?: true,
        workspaces: [%Workspace{id: 0, kind: :manual, label: "Files", icon: "folder"}]
      }

      {cmd1, caches} = WorkspacesEncoder.encode(model, Caches.new())
      {cmd2, _caches} = WorkspacesEncoder.encode(model, caches)

      assert cmd1 != nil
      assert cmd2 == nil
    end

    test "raises when the canonical command exceeds len16 payload bounds" do
      large_label = String.duplicate("l", 30_000)
      large_path = "/tmp/" <> String.duplicate("p", 30_000)

      model = %Workspaces{
        visible?: true,
        active_workspace_id: 1,
        visible_tabs: [
          %VisibleTab{id: 1, workspace_id: 1, label: large_label, path: large_path, icon: "x"},
          %VisibleTab{id: 2, workspace_id: 1, label: large_label, path: large_path, icon: "x"}
        ]
      }

      assert %{command: :gui_workspaces, field: :payload, actual: actual, min: 0, max: 65_535} =
               assert_raise(EncodingError, fn -> WorkspacesEncoder.encode_command(model) end)

      assert actual > 65_535
    end
  end

  defp full_model do
    %Workspaces{
      visible?: true,
      active_workspace_id: 2,
      mode: :agent,
      attention_count: 1,
      workspaces: [
        %Workspace{id: 1, kind: :manual, label: "Files", icon: "folder", tab_count: 1},
        %Workspace{
          id: 2,
          kind: :agent,
          label: "Agent",
          icon: "robot",
          color: 0x123456,
          status: :tool_executing,
          attention?: true,
          tab_count: 3,
          draft_count: 4,
          conflict_count: 5,
          running_background_count: 6,
          closeable?: true
        }
      ],
      visible_tabs: [
        %VisibleTab{
          id: 7,
          workspace_id: 2,
          label: "README.md",
          icon: "󰈙",
          path: "/project/README.md",
          dirty?: true,
          draft_state: :conflict,
          attention?: true,
          pinned?: true,
          tint_color: 0x654321
        },
        %VisibleTab{id: 8, workspace_id: 2, kind: :agent, label: "Agent", icon: "cpu"},
        %VisibleTab{id: 9, workspace_id: 2, label: "Untitled-1", icon: "󰈔", ephemeral?: true}
      ]
    }
  end

  defp decode_workspace(
         <<id::16, kind::8, status::8, flags::16, r::8, g::8, b::8, tab_count::16,
           draft_count::16, conflict_count::16, running_background_count::16, label_len::8,
           label::binary-size(label_len), icon_len::8, icon::binary-size(icon_len), rest::binary>>
       ) do
    color = r <<< 16 ||| g <<< 8 ||| b

    {%{
       id: id,
       kind: kind,
       status: status,
       flags: flags,
       color: color,
       tab_count: tab_count,
       draft_count: draft_count,
       conflict_count: conflict_count,
       running_background_count: running_background_count,
       label: label,
       icon: icon
     }, rest}
  end

  defp decode_visible_tab(
         <<id::32, workspace_id::16, kind::8, flags::16, path_hash::32, icon_len::8,
           icon::binary-size(icon_len), label_len::16, label::binary-size(label_len),
           path_len::16, path::binary-size(path_len), tint::32, rest::binary>>
       ) do
    {%{
       id: id,
       workspace_id: workspace_id,
       kind: kind,
       flags: flags,
       path_hash: path_hash,
       icon: icon,
       label: label,
       path: path,
       tint: tint
     }, rest}
  end
end
