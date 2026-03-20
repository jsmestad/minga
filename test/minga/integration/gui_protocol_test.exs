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

  describe "gui_gutter" do
    test "round-trips gutter with entries", %{port: port} do
      gutter_data = %{
        window_id: 1,
        content_row: 0,
        content_col: 5,
        content_height: 24,
        is_active: true,
        cursor_line: 10,
        line_number_style: :hybrid,
        line_number_width: 4,
        sign_col_width: 1,
        entries: [
          %{buf_line: 8, display_type: :normal, sign_type: :git_added},
          %{buf_line: 9, display_type: :fold_start, sign_type: :none},
          %{buf_line: 10, display_type: :wrap_continuation, sign_type: :diag_error}
        ]
      }

      cmd = ProtocolGUI.encode_gui_gutter(gutter_data)
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_gutter"
      assert decoded["window_id"] == 1
      assert decoded["content_col"] == 5
      assert decoded["content_height"] == 24
      assert decoded["is_active"] == true
      assert decoded["cursor_line"] == 10
      assert decoded["line_number_style"] == 0
      assert decoded["line_number_width"] == 4
      assert decoded["sign_col_width"] == 1
      assert length(decoded["entries"]) == 3

      [e1, e2, e3] = decoded["entries"]
      assert e1["buf_line"] == 8
      assert e1["display_type"] == 0
      assert e1["sign_type"] == 1
      assert e2["display_type"] == 1
      assert e3["display_type"] == 3
      assert e3["sign_type"] == 4
    end
  end

  describe "gui_completion visible" do
    test "round-trips visible completion with items", %{port: port} do
      comp = %Minga.Completion{
        items: [],
        filtered: [
          %{
            label: "def",
            kind: :keyword,
            insert_text: "def",
            filter_text: "def",
            detail: "keyword",
            documentation: "",
            sort_text: "def",
            text_edit: nil,
            additional_text_edits: [],
            deprecated: false,
            preselect: false,
            data: nil,
            commit_characters: []
          },
          %{
            label: "defmodule",
            kind: :keyword,
            insert_text: "defmodule",
            filter_text: "defmodule",
            detail: "keyword",
            documentation: "",
            sort_text: "defmodule",
            text_edit: nil,
            additional_text_edits: [],
            deprecated: false,
            preselect: false,
            data: nil,
            commit_characters: []
          }
        ],
        selected: 0,
        trigger_position: {5, 0},
        max_visible: 10
      }

      cmd = ProtocolGUI.encode_gui_completion(comp, 5, 0)
      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_completion"
      assert decoded["visible"] == true
      assert decoded["anchor_row"] == 5
      assert decoded["anchor_col"] == 0
      assert decoded["selected_index"] == 0
      assert length(decoded["items"]) == 2
      assert hd(decoded["items"])["label"] == "def"
    end
  end

  describe "gui_which_key visible" do
    test "round-trips visible which-key with bindings", %{port: port} do
      # Build raw binary: visible=1, prefix="SPC", page=0, pageCount=2, 2 bindings
      prefix = "SPC"

      binding1 =
        <<0::8, 1::8, "f"::binary, 9::16, "Find file"::binary, 0::8>>

      binding2 =
        <<1::8, 1::8, "b"::binary, 7::16, "Buffers"::binary, 0::8>>

      cmd =
        <<0x72, 1::8, byte_size(prefix)::16, prefix::binary, 0::8, 2::8, 2::16, binding1::binary,
          binding2::binary>>

      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_which_key"
      assert decoded["visible"] == true
      assert decoded["prefix"] == "SPC"
      assert decoded["page"] == 0
      assert decoded["page_count"] == 2
      assert length(decoded["bindings"]) == 2

      [b1, b2] = decoded["bindings"]
      assert b1["kind"] == 0
      assert b1["key"] == "f"
      assert b1["description"] == "Find file"
      assert b2["kind"] == 1
      assert b2["key"] == "b"
      assert b2["description"] == "Buffers"
    end
  end

  describe "gui_picker visible" do
    test "round-trips visible picker with items", %{port: port} do
      title = "Find File"
      query = "edi"

      # Item: icon_color(3) + flags(1) + label_len(2) + label + desc_len(2) + desc
      #       + annotation_len(2) + annotation + match_pos_count(1) + positions(2 each)
      item1 =
        <<0x51, 0xAF, 0xEF, 0x00, 9::16, "editor.ex"::binary, 3::16, "lib"::binary, 0::16, 2::8,
          0::16, 3::16>>

      cmd =
        <<0x77, 1::8, 0::16, 1::16, 10::16, byte_size(title)::16, title::binary,
          byte_size(query)::16, query::binary, 0::8, 1::16, item1::binary, 0::8>>

      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_picker"
      assert decoded["visible"] == true
      assert decoded["title"] == "Find File"
      assert decoded["query"] == "edi"
      assert decoded["filtered_count"] == 1
      assert decoded["total_count"] == 10
      assert length(decoded["items"]) == 1

      item = hd(decoded["items"])
      assert item["label"] == "editor.ex"
      assert item["description"] == "lib"
      assert item["match_positions"] == [0, 3]
    end
  end

  describe "gui_picker_preview visible" do
    test "round-trips visible preview with styled lines", %{port: port} do
      # Line 1: 2 segments
      seg1 = <<0x51, 0xAF, 0xEF, 0x01, 4::16, "def "::binary>>
      seg2 = <<0xEC, 0xBE, 0x7B, 0x00, 5::16, "hello"::binary>>
      # Line 2: 1 segment
      seg3 = <<0xBB, 0xC2, 0xCF, 0x00, 3::16, ":ok"::binary>>

      cmd =
        <<0x7D, 1::8, 2::16, 2::8, seg1::binary, seg2::binary, 1::8, seg3::binary>>

      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_picker_preview"
      assert decoded["visible"] == true
      assert length(decoded["lines"]) == 2

      [[s1, s2], [s3]] = decoded["lines"]
      assert s1["text"] == "def "
      assert s1["bold"] == true
      assert s1["fg_color"] == 0x51AFEF
      assert s2["text"] == "hello"
      assert s2["bold"] == false
      assert s3["text"] == ":ok"
    end
  end

  describe "gui_bottom_panel visible" do
    test "round-trips visible bottom panel with tabs and entries", %{port: port} do
      # Tab: type=0 (messages), name="Messages"
      tab = <<0::8, 8::8, "Messages"::binary>>

      # Entry: id(4) + level(1) + subsystem(1) + timestamp(4) + path_len(2) + path + text_len(2) + text
      path = "lib/editor.ex"
      text = "File opened"

      entry =
        <<42::32, 1::8, 0::8, 3661::32, byte_size(path)::16, path::binary, byte_size(text)::16,
          text::binary>>

      cmd =
        <<0x7C, 1::8, 0::8, 30::8, 0::8, 1::8, tab::binary, 1::16, entry::binary>>

      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_bottom_panel"
      assert decoded["visible"] == true
      assert decoded["active_tab_index"] == 0
      assert decoded["height_percent"] == 30
      assert length(decoded["tabs"]) == 1
      assert hd(decoded["tabs"])["name"] == "Messages"
      assert length(decoded["entries"]) == 1

      entry_decoded = hd(decoded["entries"])
      assert entry_decoded["id"] == 42
      assert entry_decoded["level"] == 1
      assert entry_decoded["text"] == "File opened"
    end
  end

  describe "gui_tool_manager visible" do
    test "round-trips visible tool manager with tools", %{port: port} do
      # Tool: name_len(1)+name, label_len(1)+label, desc_len(2)+desc,
      #       category(1)+status(1)+method(1)+lang_count(1),
      #       lang_len(1)+lang, version_len(1)+version,
      #       homepage_len(2)+homepage, provides_count(1)+provides_len(1)+provides
      name = "elixir_ls"
      label = "ElixirLS"
      desc = "Elixir LSP"
      lang = "elixir"
      version = "0.22"
      homepage = "https://github.com/elixir-lsp/elixir-ls"
      provides = "elixir-ls"

      tool =
        <<byte_size(name)::8, name::binary, byte_size(label)::8, label::binary,
          byte_size(desc)::16, desc::binary, 0::8, 1::8, 0::8, 1::8, byte_size(lang)::8,
          lang::binary, byte_size(version)::8, version::binary, byte_size(homepage)::16,
          homepage::binary, 1::8, byte_size(provides)::8, provides::binary>>

      cmd = <<0x7E, 1::8, 0::8, 0::16, 1::16, tool::binary>>

      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_tool_manager"
      assert decoded["visible"] == true
      assert decoded["filter"] == 0
      assert length(decoded["tools"]) == 1

      t = hd(decoded["tools"])
      assert t["name"] == "elixir_ls"
      assert t["label"] == "ElixirLS"
      assert t["description"] == "Elixir LSP"
      assert t["category"] == 0
      assert t["status"] == 1
      assert t["languages"] == ["elixir"]
      assert t["version"] == "0.22"
      assert t["homepage"] == "https://github.com/elixir-lsp/elixir-ls"
      assert t["provides"] == ["elixir-ls"]
    end
  end

  describe "gui_file_tree visible" do
    test "round-trips visible file tree with entries", %{port: port} do
      # Raw binary: selected_index(2), tree_width(2), entry_count(2), root_len(2), root
      # Per entry: path_hash(4), flags(1), depth(1), git_status(1), icon_len(1), icon,
      #            name_len(2), name, rel_path_len(2), rel_path
      root = "/project"
      name1 = "lib"
      rel1 = "lib"
      icon1 = <<0xF0, 0x9F, 0x93, 0x81>>
      name2 = "editor.ex"
      rel2 = "lib/editor.ex"

      entry1 =
        <<0xAA, 0xBB, 0xCC, 0xDD::8, 0x07::8, 0::8, 0::8, byte_size(icon1)::8, icon1::binary,
          byte_size(name1)::16, name1::binary, byte_size(rel1)::16, rel1::binary>>

      entry2 =
        <<0x11, 0x22, 0x33, 0x44::8, 0x00::8, 1::8, 1::8, 0::8, byte_size(name2)::16,
          name2::binary, byte_size(rel2)::16, rel2::binary>>

      cmd =
        <<0x70, 1::16, 30::16, 2::16, byte_size(root)::16, root::binary, entry1::binary,
          entry2::binary>>

      Port.command(port, cmd)

      assert_receive {^port, {:data, json}}, 5_000
      decoded = Jason.decode!(json)

      assert decoded["type"] == "gui_file_tree"
      assert decoded["selected_index"] == 1
      assert decoded["tree_width"] == 30
      assert decoded["root_path"] == "/project"
      assert length(decoded["entries"]) == 2

      [e1, e2] = decoded["entries"]
      assert e1["name"] == "lib"
      assert e1["is_dir"] == true
      assert e1["is_expanded"] == true
      assert e1["is_selected"] == true
      assert e1["depth"] == 0
      assert e2["name"] == "editor.ex"
      assert e2["is_dir"] == false
      assert e2["depth"] == 1
      assert e2["git_status"] == 1
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
