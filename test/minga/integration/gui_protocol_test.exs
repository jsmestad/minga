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

  setup do
    if not File.exists?(@harness_path) do
      flunk(
        "Test harness not found at #{@harness_path}. Build with: swiftc -o priv/minga-test-harness macos/Sources/Protocol/ProtocolConstants.swift macos/Sources/Protocol/ProtocolDecoder.swift macos/Sources/TestHarness/main.swift"
      )
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

    test "gui_status_bar encodes and decodes correctly", %{port: port} do
      data = %{
        mode: :normal,
        cursor_line: 42,
        cursor_col: 10,
        line_count: 200,
        filetype: :elixir,
        dirty_marker: "●",
        lsp_status: :ready,
        git_branch: "main",
        status_msg: ""
      }

      cmd = ProtocolGUI.encode_gui_status_bar(data)
      Port.command(port, cmd)
      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_status_bar"
      assert decoded["mode"] == 0
      assert decoded["cursor_line"] == 42
      assert decoded["cursor_col"] == 10
      assert decoded["line_count"] == 200
      assert decoded["git_branch"] == "main"
      assert decoded["filetype"] == "elixir"
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
end
