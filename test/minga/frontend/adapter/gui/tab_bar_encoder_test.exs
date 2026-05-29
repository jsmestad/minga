defmodule Minga.Frontend.Adapter.GUI.TabBarEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.TabBarEncoder
  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary

  @op_gui_tab_bar Minga.Protocol.Opcodes.gui_tab_bar()

  describe "encode/2" do
    test "returns nil when tab bar is hidden" do
      assert {nil, _caches} = TabBarEncoder.encode(%TabBar{}, Caches.new())
    end

    test "matches legacy ChromeState wire format" do
      chrome_state = chrome_state()

      model = %TabBar{
        visible?: true,
        active_tab_id: chrome_state.active_tab_id,
        tabs: [
          %Tab{
            id: 7,
            workspace_id: 2,
            label: "README.md",
            icon: "󰈙",
            dirty?: true,
            attention?: true,
            pinned?: true,
            tint_color: 0x123456
          }
        ]
      }

      {cmd, _caches} = TabBarEncoder.encode(model, Caches.new())

      assert cmd == ProtocolGUI.encode_gui_tab_bar(chrome_state)
    end

    test "encodes semantic tabs" do
      model = %TabBar{
        visible?: true,
        active_tab_id: 1,
        tabs: [
          %Tab{id: 1, workspace_id: 0, label: "README.md", icon: "󰈙", dirty?: true, pinned?: true}
        ]
      }

      {cmd, _caches} = TabBarEncoder.encode(model, Caches.new())

      assert <<@op_gui_tab_bar, 0::8, 1::8, flags::8, 1::32, 0::16, rest::binary>> = cmd
      assert Bitwise.band(flags, 0x01) == 0x01
      assert Bitwise.band(flags, 0x02) == 0x02
      assert Bitwise.band(flags, 0x80) == 0x80
      assert byte_size(rest) > 0
    end

    test "encodes agent tab flags" do
      model = %TabBar{
        visible?: true,
        active_tab_id: 9,
        tabs: [
          %Tab{
            id: 9,
            workspace_id: 1,
            label: "Agent",
            icon: "󰚩",
            kind: :agent,
            attention?: true,
            agent_status: :thinking
          }
        ]
      }

      {cmd, _caches} = TabBarEncoder.encode(model, Caches.new())

      assert <<@op_gui_tab_bar, 0::8, 1::8, flags::8, _rest::binary>> = cmd
      assert Bitwise.band(flags, 0x01) == 0x01
      assert Bitwise.band(flags, 0x04) == 0x04
      assert Bitwise.band(flags, 0x08) == 0x08
      assert Bitwise.band(flags, 0x70) == 0x10
    end

    test "returns nil on second call with same semantic data" do
      model = %TabBar{
        visible?: true,
        active_tab_id: 1,
        tabs: [%Tab{id: 1, workspace_id: 0, label: "one", icon: "x"}]
      }

      {cmd1, caches} = TabBarEncoder.encode(model, Caches.new())
      {cmd2, _caches} = TabBarEncoder.encode(model, caches)

      assert cmd1 != nil
      assert cmd2 == nil
    end

    test "re-encodes when semantic data changes" do
      model1 = %TabBar{
        visible?: true,
        active_tab_id: 1,
        tabs: [%Tab{id: 1, workspace_id: 0, label: "one", icon: "x"}]
      }

      model2 = %TabBar{
        visible?: true,
        active_tab_id: 2,
        tabs: [%Tab{id: 2, workspace_id: 0, label: "two", icon: "x"}]
      }

      {_, caches} = TabBarEncoder.encode(model1, Caches.new())
      {cmd2, _caches} = TabBarEncoder.encode(model2, caches)

      assert <<@op_gui_tab_bar, 0::8, 1::8, _rest::binary>> = cmd2
    end
  end

  @spec chrome_state() :: ChromeState.t()
  defp chrome_state do
    %ChromeState{
      workspaces: [],
      visible_tabs: [
        TabSummary.new(
          id: 7,
          workspace_id: 2,
          kind: :file,
          label: "README.md",
          path: "/project/README.md",
          icon: "󰈙",
          dirty?: true,
          draft_state: :none,
          attention?: true,
          pinned?: true,
          tint_color: 0x123456
        )
      ],
      mode: :editor,
      active_workspace_id: 2,
      active_tab_id: 7,
      background_count: 0,
      attention_count: 1,
      draft_count: 0,
      conflict_count: 0
    }
  end
end
