defmodule Minga.Frontend.Adapter.GUI.WorkspacesEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WorkspacesEncoder
  alias Minga.RenderModel.UI.Workspaces
  alias Minga.RenderModel.UI.Workspaces.VisibleTab
  alias Minga.RenderModel.UI.Workspaces.Workspace
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary
  alias MingaEditor.Session.ChromeState.WorkspaceSummary

  @op_gui_workspaces Minga.Protocol.Opcodes.gui_workspaces()

  describe "encode/2" do
    test "returns nil when workspaces are hidden" do
      assert {nil, _caches} = WorkspacesEncoder.encode(%Workspaces{}, Caches.new())
    end

    test "matches legacy ChromeState wire format" do
      chrome_state = chrome_state()

      model = %Workspaces{
        visible?: true,
        active_workspace_id: chrome_state.active_workspace_id,
        mode: chrome_state.mode,
        attention_count: chrome_state.attention_count,
        workspaces: [
          %Workspace{
            id: 2,
            kind: :agent,
            label: "Agent",
            icon: "robot",
            color: 0x123456,
            status: :thinking,
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
          }
        ]
      }

      {cmd, _caches} = WorkspacesEncoder.encode(model, Caches.new())

      assert cmd == ProtocolGUI.encode_gui_workspaces(chrome_state)
    end

    test "encodes workspace and visible tab summaries" do
      model = %Workspaces{
        visible?: true,
        active_workspace_id: 0,
        mode: :editor,
        workspaces: [
          %Workspace{id: 0, kind: :manual, label: "Files", icon: "folder", tab_count: 1}
        ],
        visible_tabs: [
          %VisibleTab{id: 7, workspace_id: 0, label: "README.md", icon: "󰈙", path: "/p/README.md"}
        ]
      }

      {cmd, _caches} = WorkspacesEncoder.encode(model, Caches.new())

      assert <<@op_gui_workspaces, len::16, payload::binary-size(len)>> = cmd
      assert <<2::8, 0::16, 0::8, 0::8, 1::8, _rest::binary>> = payload
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
  end

  @spec chrome_state() :: ChromeState.t()
  defp chrome_state do
    %ChromeState{
      workspaces: [
        WorkspaceSummary.new(
          id: 2,
          kind: :agent,
          label: "Agent",
          icon: "robot",
          color: 0x123456,
          status: :thinking,
          attention?: true,
          tab_count: 3,
          draft_count: 4,
          conflict_count: 5,
          running_background_count: 6,
          closeable?: true
        )
      ],
      visible_tabs: [
        TabSummary.new(
          id: 7,
          workspace_id: 2,
          kind: :file,
          label: "README.md",
          path: "/project/README.md",
          icon: "󰈙",
          dirty?: true,
          draft_state: :conflict,
          attention?: true,
          pinned?: true,
          tint_color: 0x654321
        )
      ],
      mode: :agent,
      active_workspace_id: 2,
      active_tab_id: 7,
      background_count: 6,
      attention_count: 1,
      draft_count: 4,
      conflict_count: 5
    }
  end
end
