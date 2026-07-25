defmodule Minga.Frontend.Adapter.GUI.TabBarEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.TabBarEncoder
  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab

  @op_gui_tab_bar Minga.Protocol.Opcodes.gui_tab_bar()

  describe "encode/2" do
    test "returns nil when tab bar is hidden" do
      assert {nil, _caches} = TabBarEncoder.encode(%TabBar{}, Caches.new())
    end

    test "encodes semantic tab bytes directly" do
      model = %TabBar{
        visible?: true,
        active_tab_id: 7,
        tabs: [
          %Tab{
            id: 3,
            workspace_id: 1,
            label: "agent",
            icon: "A",
            kind: :agent,
            attention?: true,
            agent_status: :tool_executing,
            tint_color: 0x7AA2F7
          },
          %Tab{
            id: 7,
            workspace_id: 2,
            label: "README.md",
            icon: "󰈙",
            dirty?: true,
            pinned?: true,
            tint_color: 0x123456
          }
        ]
      }

      {cmd, _caches} = TabBarEncoder.encode(model, Caches.new())

      assert <<@op_gui_tab_bar, 1::8, 2::8, entries::binary>> = cmd
      {agent_tab, entries} = decode_tab(entries)
      {file_tab, ""} = decode_tab(entries)

      assert agent_tab == %{
               flags: 0x2C,
               id: 3,
               workspace_id: 1,
               icon: "A",
               label: "agent",
               tint_color: 0x7AA2F7
             }

      assert file_tab == %{
               flags: 0x83,
               id: 7,
               workspace_id: 2,
               icon: "󰈙",
               label: "README.md",
               tint_color: 0x123456
             }
    end

    test "encodes every agent status in bits 4 through 6" do
      for {status, expected} <- [
            {nil, 0},
            {:idle, 0},
            {:thinking, 1},
            {:tool_executing, 2},
            {:error, 3},
            {:plan, 4},
            {:unknown, 0}
          ] do
        model = %TabBar{
          visible?: true,
          active_tab_id: 1,
          tabs: [
            %Tab{
              id: 1,
              workspace_id: 0,
              label: "Agent",
              icon: "A",
              kind: :agent,
              agent_status: status
            }
          ]
        }

        assert <<@op_gui_tab_bar, 0::8, 1::8, flags::8, _rest::binary>> =
                 TabBarEncoder.encode_command(model)

        assert Bitwise.band(flags, 0x04) == 0x04
        assert Bitwise.band(Bitwise.bsr(flags, 4), 0x07) == expected
      end
    end

    test "uses hidden-active sentinel when no visible tab is active" do
      model = %TabBar{
        visible?: true,
        active_tab_id: nil,
        tabs: [%Tab{id: 1, workspace_id: 2, label: "other.ex", icon: ""}]
      }

      assert <<@op_gui_tab_bar, 255::8, 1::8, flags::8, _rest::binary>> =
               TabBarEncoder.encode_command(model)

      assert Bitwise.band(flags, 0x01) == 0
    end

    test "encodes ephemeral file tabs in bit 4 without agent bit" do
      model = %TabBar{
        visible?: true,
        active_tab_id: 1,
        tabs: [%Tab{id: 1, workspace_id: 0, label: "Untitled-1", icon: "󰈔", ephemeral?: true}]
      }

      {cmd, _caches} = TabBarEncoder.encode(model, Caches.new())

      assert <<@op_gui_tab_bar, 0::8, 1::8, flags::8, _rest::binary>> = cmd
      assert Bitwise.band(flags, 0x04) == 0x00
      assert Bitwise.band(flags, 0x10) == 0x10
    end

    test "file tabs with a backing file do not set the ephemeral bit" do
      model = %TabBar{
        visible?: true,
        active_tab_id: 1,
        tabs: [%Tab{id: 1, workspace_id: 0, label: "README.md", icon: "󰈙"}]
      }

      {cmd, _caches} = TabBarEncoder.encode(model, Caches.new())

      assert <<@op_gui_tab_bar, 0::8, 1::8, flags::8, _rest::binary>> = cmd
      assert Bitwise.band(flags, 0x70) == 0x00
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

  defp decode_tab(
         <<flags::8, id::32, workspace_id::16, icon_len::8, icon::binary-size(icon_len),
           label_len::16, label::binary-size(label_len), tint_color::32, rest::binary>>
       ) do
    {%{
       flags: flags,
       id: id,
       workspace_id: workspace_id,
       icon: icon,
       label: label,
       tint_color: tint_color
     }, rest}
  end
end
