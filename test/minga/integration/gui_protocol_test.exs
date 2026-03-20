defmodule Minga.Integration.GUIProtocolTest do
  @moduledoc """
  Integration tests for the BEAM to Swift GUI protocol round-trip.

  Spawns the headless Swift test harness as an Erlang Port, sends encoded
  GUI protocol opcodes, and asserts the harness decoded them correctly by
  checking its JSON output.
  """

  use ExUnit.Case, async: false

  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

  @harness_path Path.join(:code.priv_dir(:minga), "minga-test-harness")

  @moduletag :swift_harness

  setup do
    unless File.exists?(@harness_path) do
      flunk("Test harness not found at #{@harness_path}. Run: mix swift.harness")
    end

    port = Port.open({:spawn_executable, @harness_path}, [:binary, {:packet, 4}])

    # Wait for the ready signal from the harness.
    assert_receive {^port, {:data, ready_json}}, 5_000
    assert %{"type" => "ready"} = Jason.decode!(ready_json)

    on_exit(fn ->
      if Port.info(port) != nil do
        Port.close(port)
      end
    end)

    %{port: port}
  end

  describe "GUI chrome opcode round-trip" do
    test "gui_theme encodes and decodes correctly", %{port: port} do
      theme = Minga.Theme.get!(:doom_one)
      cmd = ProtocolGUI.encode_gui_theme(theme)

      Port.command(port, cmd)
      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_theme"
      assert is_list(decoded["slots"])
      assert length(decoded["slots"]) > 20

      # Verify a specific slot (editor_bg = slot 0x01)
      editor_bg_slot = Enum.find(decoded["slots"], fn s -> s["slot"] == 1 end)
      assert editor_bg_slot != nil
      assert is_integer(editor_bg_slot["r"])
      assert is_integer(editor_bg_slot["g"])
      assert is_integer(editor_bg_slot["b"])
    end

    test "gui_tab_bar encodes and decodes correctly", %{port: port} do
      tab1 = %Minga.Editor.State.Tab{id: 1, kind: :file, label: "editor.ex"}
      tab2 = %Minga.Editor.State.Tab{id: 2, kind: :agent, label: "Agent", agent_status: :thinking}
      tb = %Minga.Editor.State.TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}

      cmd = ProtocolGUI.encode_gui_tab_bar(tb)
      Port.command(port, cmd)

      # With 2 tabs, the harness sends both a JSON report and a gui_action.
      # Find the JSON one.
      messages =
        for _ <- 1..2,
            do:
              (
                assert_receive {^port, {:data, d}}, 5_000
                d
              )

      json = Enum.find(messages, &String.starts_with?(&1, "{"))
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_tab_bar"
      assert decoded["active_index"] == 0
      assert length(decoded["tabs"]) == 2

      [t1, t2] = decoded["tabs"]
      assert t1["id"] == 1
      assert t1["label"] == "editor.ex"
      assert t1["is_active"] == true
      assert t2["id"] == 2
      assert t2["label"] == "Agent"
      assert t2["is_agent"] == true
    end

    test "gui_breadcrumb encodes and decodes correctly", %{port: port} do
      cmd =
        ProtocolGUI.encode_gui_breadcrumb("/home/user/project/lib/foo.ex", "/home/user/project")

      Port.command(port, cmd)
      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_breadcrumb"
      assert decoded["segments"] == ["lib", "foo.ex"]
    end

    test "gui_status_bar buffer variant encodes and decodes correctly", %{port: port} do
      data =
        {:buffer,
         %{
           mode: :normal,
           mode_state: nil,
           cursor_line: 41,
           cursor_col: 9,
           line_count: 200,
           file_name: "foo.ex",
           filetype: :elixir,
           dirty: true,
           git_branch: "main",
           git_diff_summary: nil,
           diagnostic_counts: nil,
           lsp_status: :ready,
           parser_status: :available,
           buf_index: 1,
           buf_count: 3,
           macro_recording: false,
           agent_status: nil,
           agent_theme_colors: nil
         }}

      cmd = ProtocolGUI.encode_gui_status_bar(data)
      Port.command(port, cmd)
      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_status_bar"
      # content_kind 0 = buffer
      assert decoded["content_kind"] == 0
      assert decoded["mode"] == 0
      # 1-indexed in the wire format (cursor_line is 0-indexed internally, +1 encoded)
      assert decoded["cursor_line"] == 42
      assert decoded["cursor_col"] == 10
      assert decoded["line_count"] == 200
      assert decoded["git_branch"] == "main"
      assert decoded["filetype"] == "elixir"
    end

    test "gui_status_bar agent variant encodes and decodes correctly", %{port: port} do
      data =
        {:agent,
         %{
           mode: :normal,
           mode_state: nil,
           model_name: "claude-3-5-sonnet",
           session_status: :thinking,
           message_count: 7,
           macro_recording: false,
           agent_status: :thinking,
           agent_theme_colors: nil
         }}

      cmd = ProtocolGUI.encode_gui_status_bar(data)
      Port.command(port, cmd)
      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_status_bar"
      # content_kind 1 = agent
      assert decoded["content_kind"] == 1
      assert decoded["mode"] == 0
      assert decoded["model_name"] == "claude-3-5-sonnet"
      assert decoded["message_count"] == 7
    end

    test "gui_agent_chat hidden encodes and decodes correctly", %{port: port} do
      cmd = ProtocolGUI.encode_gui_agent_chat(%{visible: false})
      Port.command(port, cmd)
      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_agent_chat"
      assert decoded["visible"] == false
    end

    test "gui_agent_chat visible with messages", %{port: port} do
      data = %{
        visible: true,
        messages: [{:user, "hello"}, {:assistant, "hi there"}],
        status: :idle,
        model: "claude",
        prompt: "test prompt",
        pending_approval: nil
      }

      cmd = ProtocolGUI.encode_gui_agent_chat(data)
      Port.command(port, cmd)
      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_agent_chat"
      assert decoded["visible"] == true
      assert decoded["model"] == "claude"
      assert decoded["prompt"] == "test prompt"
      assert length(decoded["messages"]) == 2

      [msg1, msg2] = decoded["messages"]
      assert msg1["kind"] == "user"
      assert msg1["text"] == "hello"
      assert msg2["kind"] == "assistant"
      assert msg2["text"] == "hi there"
    end
  end

  describe "round-trip: BEAM encode → harness decode → harness sends gui_action → BEAM receives" do
    test "tab bar triggers harness to send select_tab gui_action back", %{port: port} do
      alias Minga.Port.Protocol

      # Step 1: Send a gui_tab_bar with 2 tabs. The harness will decode it
      # and automatically send a gui_action select_tab for the second tab.
      tab1 = %Minga.Editor.State.Tab{id: 1, kind: :file, label: "main.ex"}
      tab2 = %Minga.Editor.State.Tab{id: 2, kind: :file, label: "test.ex"}
      tb = %Minga.Editor.State.TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}

      cmd = ProtocolGUI.encode_gui_tab_bar(tb)
      Port.command(port, cmd)

      # Step 2: We should receive two messages:
      # (a) The JSON report of the decoded gui_tab_bar
      # (b) The raw gui_action binary (select_tab for tab id=2)
      # Order may vary, so collect both.
      messages =
        Enum.map(1..2, fn _ ->
          assert_receive {^port, {:data, data}}, 5_000
          data
        end)

      # Find the JSON report.
      json_msg = Enum.find(messages, fn d -> String.starts_with?(d, "{") end)
      assert json_msg != nil
      tab_decoded = Jason.decode!(json_msg)
      assert tab_decoded["type"] == "gui_tab_bar"
      assert length(tab_decoded["tabs"]) == 2

      # Find the gui_action binary and decode it on the BEAM side.
      action_msg = Enum.find(messages, fn d -> not String.starts_with?(d, "{") end)
      assert action_msg != nil
      assert {:ok, {:gui_action, {:select_tab, 2}}} = Protocol.decode_event(action_msg)
    end
  end

  describe "gui_gutter_separator" do
    test "round-trips gutter separator col and color", %{port: port} do
      cmd = ProtocolGUI.encode_gui_gutter_separator(4, 0x3F444A)
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_gutter_separator"
      assert decoded["col"] == 4
      assert decoded["r"] == 0x3F
      assert decoded["g"] == 0x44
      assert decoded["b"] == 0x4A
    end
  end

  describe "gui_completion hidden" do
    test "round-trips hidden completion", %{port: port} do
      cmd = ProtocolGUI.encode_gui_completion(nil, 0, 0)
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_completion"
      assert decoded["visible"] == false
    end
  end

  describe "gui_which_key hidden" do
    test "round-trips hidden which-key", %{port: port} do
      cmd = ProtocolGUI.encode_gui_which_key(%{show: false})
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_which_key"
      assert decoded["visible"] == false
    end
  end

  describe "gui_picker hidden" do
    test "round-trips hidden picker", %{port: port} do
      cmd = ProtocolGUI.encode_gui_picker(nil)
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_picker"
      assert decoded["visible"] == false
    end
  end

  describe "gui_bottom_panel hidden" do
    test "round-trips hidden bottom panel", %{port: port} do
      alias Minga.Panel.MessageStore
      {cmd, _store} = ProtocolGUI.encode_gui_bottom_panel(%{visible: false}, %MessageStore{})
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_bottom_panel"
      assert decoded["visible"] == false
    end
  end

  describe "gui_tool_manager hidden" do
    test "round-trips hidden tool manager", %{port: port} do
      cmd = ProtocolGUI.encode_gui_tool_manager(nil)
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_tool_manager"
      assert decoded["visible"] == false
    end
  end

  describe "gui_cursorline" do
    test "round-trips cursorline row and bg color", %{port: port} do
      cmd = ProtocolGUI.encode_gui_cursorline(12, 0x2C323C)
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_cursorline"
      assert decoded["row"] == 12
      assert decoded["r"] == 0x2C
      assert decoded["g"] == 0x32
      assert decoded["b"] == 0x3C
    end

    test "round-trips no cursorline (0xFFFF)", %{port: port} do
      cmd = ProtocolGUI.encode_gui_cursorline(0xFFFF, 0)
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_cursorline"
      assert decoded["row"] == 0xFFFF
      assert decoded["r"] == 0
      assert decoded["g"] == 0
      assert decoded["b"] == 0
    end
  end
end
