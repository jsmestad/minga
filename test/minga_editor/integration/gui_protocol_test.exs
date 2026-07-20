defmodule Minga.Integration.GUIProtocolTest do
  @moduledoc """
  Integration tests for the BEAM to Swift GUI protocol round-trip.

  Spawns the headless Swift test harness as an Erlang Port, sends encoded
  GUI protocol opcodes, and asserts the harness decoded them correctly by
  checking its JSON output.
  """

  # async: false: spawns the headless Swift test harness as a real OS process via Port.open/2
  use ExUnit.Case, async: false

  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.Frontend.Adapter.GUI.WhichKeyEncoder
  alias Minga.Frontend.Adapter.GUI.TabBarEncoder
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.FileTree
  alias Minga.RenderModel.UI.FileTree.Editing
  alias Minga.RenderModel.UI.FileTree.Flags
  alias Minga.RenderModel.UI.FileTree.Row
  alias Minga.RenderModel.UI.Picker, as: PickerModel
  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Agent
  alias Minga.RenderModel.UI.StatusBar.Cursor
  alias Minga.RenderModel.UI.StatusBar.Data
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.File, as: StatusFile
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
  alias Minga.RenderModel.UI.StatusBar.Selection
  alias Minga.Test.GUIHarness
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.RenderModel.UI.BreadcrumbBuilder
  alias MingaEditor.RenderModel.UI.ThemeBuilder

  @harness_path Path.join(:code.priv_dir(:minga), "minga-test-harness")

  @moduletag :swift_harness

  setup_all do
    unless File.exists?(@harness_path) do
      flunk("Test harness not found at #{@harness_path}. Run: mix swift.harness")
    end

    {:ok, harness} = start_supervised({GUIHarness, path: @harness_path})
    %{harness: harness}
  end

  defp round_trip(harness, command, expected_type) do
    GUIHarness.round_trip!(harness, command, expected_type)
  end

  # Encodes agent-chat chrome through the core semantic encoder, accepting the
  # data-map shape these round-trip tests use.
  defp encode_gui_agent_chat(data) do
    alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
    alias Minga.Frontend.Adapter.GUI.Caches
    alias Minga.RenderModel.UI.AgentChat

    model =
      case data do
        %{visible: false} ->
          %AgentChat{visible?: false}

        %{visible: true} = d ->
          %AgentChat{
            visible?: true,
            status: Map.get(d, :status, :idle),
            model_name: Map.get(d, :model, ""),
            thinking_level: Map.get(d, :thinking_level, ""),
            prompt: Map.get(d, :prompt, ""),
            help_visible?: Map.get(d, :help_visible, false),
            help_groups: Map.get(d, :help_groups, [])
          }
      end

    {binary, _caches} = AgentChatEncoder.encode(model, Caches.new())
    binary
  end

  describe "GUI chrome opcode round-trip" do
    test "gui_theme encodes and decodes correctly", %{harness: harness} do
      model =
        :doom_one
        |> MingaEditor.UI.Theme.get!()
        |> ThemeBuilder.build()

      {cmd, _caches} = ThemeEncoder.encode(model, Caches.new())
      assert cmd != nil

      decoded = round_trip(harness, cmd, "gui_theme")

      assert decoded["type"] == "gui_theme"
      assert is_list(decoded["slots"])
      assert Enum.count(decoded["slots"]) > 20

      # Verify a specific slot (editor_bg = slot 0x01)
      editor_bg_slot = Enum.find(decoded["slots"], fn s -> s["slot"] == 1 end)
      assert editor_bg_slot != nil
      assert is_integer(editor_bg_slot["r"])
      assert is_integer(editor_bg_slot["g"])
      assert is_integer(editor_bg_slot["b"])
    end

    test "gui_tab_bar encodes and decodes correctly", %{harness: harness} do
      model = %TabBar{
        visible?: true,
        active_tab_id: 1,
        tabs: [
          %Tab{id: 1, workspace_id: 1, kind: :file, label: "editor.ex", icon: ""},
          %Tab{
            id: 2,
            workspace_id: 2,
            kind: :agent,
            label: "Agent",
            icon: "󰚩",
            agent_status: :thinking
          }
        ]
      }

      cmd = TabBarEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_tab_bar")

      assert decoded["type"] == "gui_tab_bar"
      assert decoded["active_index"] == 0
      assert Enum.count(decoded["tabs"]) == 2

      [t1, t2] = decoded["tabs"]
      assert t1["id"] == 1
      assert t1["label"] == "editor.ex"
      assert t1["is_active"] == true
      assert t1["is_agent"] == false
      assert t2["id"] == 2
      assert t2["is_agent"] == true
      assert t2["agent_status"] == 1
    end

    test "gui_breadcrumb encodes and decodes correctly", %{harness: harness} do
      model =
        BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "/home/user/project")

      {cmd, _caches} = BreadcrumbEncoder.encode(model, Caches.new())

      decoded = round_trip(harness, cmd, "gui_breadcrumb")

      assert decoded["type"] == "gui_breadcrumb"
      assert decoded["segments"] == ["lib", "foo.ex"]
    end

    test "gui_status_bar buffer variant encodes and decodes correctly", %{harness: harness} do
      model = %StatusBar{
        content_kind: :buffer,
        data: %Data{
          mode: :normal,
          safe_mode?: true,
          dirty?: true,
          cursor: %Cursor{line: 41, col: 9, line_count: 200},
          diagnostics: %Diagnostics{
            counts: {2, 4, 1, 0},
            hint: "✖ undefined function foo/0 [ElixirLS]"
          },
          language: %Language{lsp_status: :ready, parser_status: :available},
          git: %Git{branch: "main", diff_summary: {5, 3, 1}},
          file: %StatusFile{name: "foo.ex", filetype: :elixir, icon: "", icon_color: 0xA074C4},
          message: "Wrote foo.ex",
          recording: {true, "q"},
          indent: %Indent{type: :spaces, size: 2},
          selection: %Selection{mode: :chars, size: 42},
          agent: %Agent{agent_status: :thinking, active_tool_name: "read_file"},
          modeline_segments: %{
            left: [{" NORMAL ", 0xBBC2CF, 0x51AFEF, [bold: true], nil}],
            right: [{" Elixir ", 0xC678DD, 0x282C34, [], :set_language}]
          }
        }
      }

      cmd = StatusBarEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_status_bar")

      assert decoded["type"] == "gui_status_bar"
      # content_kind 0 = buffer
      assert decoded["content_kind"] == 0
      assert decoded["mode"] == 0
      assert decoded["safe_mode"] == true
      # 1-indexed in the wire format (cursor_line is 0-indexed internally, +1 encoded)
      assert decoded["cursor_line"] == 42
      assert decoded["cursor_col"] == 10
      assert decoded["line_count"] == 200
      assert decoded["git_branch"] == "main"
      assert decoded["message"] == "Wrote foo.ex"
      assert decoded["filetype"] == "elixir"
      # Extended fields (TUI modeline parity)
      assert decoded["info_count"] == 1
      assert decoded["hint_count"] == 0
      assert decoded["macro_recording"] == 17
      assert decoded["parser_status"] == 0
      assert decoded["agent_status"] == 1
      assert decoded["active_tool_name"] == "read_file"
      assert decoded["git_added"] == 5
      assert decoded["git_modified"] == 3
      assert decoded["git_deleted"] == 1
      assert decoded["filename"] == "foo.ex"
      assert decoded["diagnostic_hint"] == "✖ undefined function foo/0 [ElixirLS]"
      assert decoded["indent_type"] == 0
      assert decoded["indent_size"] == 2

      assert [%{"text" => " NORMAL ", "attrs" => 1, "command" => ""}] =
               decoded["modeline_left_segments"]

      assert [%{"text" => " Elixir ", "command" => "set_language"}] =
               decoded["modeline_right_segments"]

      assert decoded["selection_mode"] == 1
      assert decoded["selection_size"] == 42
    end

    test "gui_status_bar agent variant encodes and decodes correctly", %{harness: harness} do
      model = %StatusBar{
        content_kind: :agent,
        data: %Data{
          mode: :normal,
          safe_mode?: true,
          dirty?: true,
          cursor: %Cursor{line: 10, col: 5, line_count: 100},
          diagnostics: %Diagnostics{
            counts: {1, 2, 0, 1},
            hint: "⚠ unused variable [ElixirLS]"
          },
          language: %Language{lsp_status: :ready, parser_status: :available},
          git: %Git{branch: "feat/agent", diff_summary: {3, 2, 0}},
          file: %StatusFile{name: "editor.ex", filetype: :elixir, icon: "", icon_color: 0xA074C4},
          recording: false,
          indent: %Indent{type: :tabs, size: 4},
          selection: %Selection{mode: :lines, size: 3},
          agent: %Agent{
            model_name: "claude-3-5-sonnet",
            session_status: :thinking,
            message_count: 7,
            agent_status: :thinking,
            active_tool_name: "shell"
          }
        }
      }

      cmd = StatusBarEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_status_bar")

      assert decoded["type"] == "gui_status_bar"
      # content_kind 1 = agent
      assert decoded["content_kind"] == 1
      assert decoded["mode"] == 0
      assert decoded["safe_mode"] == true
      assert decoded["model_name"] == "claude-3-5-sonnet"
      assert decoded["message_count"] == 7
      # Background buffer fields are now populated
      assert decoded["cursor_line"] == 11
      assert decoded["cursor_col"] == 6
      assert decoded["line_count"] == 100
      assert decoded["git_branch"] == "feat/agent"
      assert decoded["filetype"] == "elixir"
      assert decoded["error_count"] == 1
      assert decoded["warning_count"] == 2
      assert decoded["hint_count"] == 1
      assert decoded["active_tool_name"] == "shell"
      assert decoded["git_added"] == 3
      assert decoded["git_modified"] == 2
      assert decoded["git_deleted"] == 0
      assert decoded["filename"] == "editor.ex"
      assert decoded["diagnostic_hint"] == "⚠ unused variable [ElixirLS]"
      assert decoded["indent_type"] == 1
      assert decoded["indent_size"] == 4
      assert decoded["selection_mode"] == 2
      assert decoded["selection_size"] == 3
    end

    test "gui_agent_chat with help overlay round-trips", %{harness: harness} do
      data = %{
        visible: true,
        status: :idle,
        model: "claude",
        prompt: "",
        pending_approval: nil,
        help_visible: true,
        help_groups: [
          {"Navigation", [{"j / k", "Scroll down / up"}, {"gg / G", "Top / bottom"}]},
          {"Copy", [{"y", "Copy code block"}]}
        ]
      }

      cmd = encode_gui_agent_chat(data)
      decoded = round_trip(harness, cmd, "gui_agent_chat")

      assert decoded["type"] == "gui_agent_chat"
      assert decoded["help_visible"] == true
      assert Enum.count(decoded["help_groups"]) == 2

      [nav, copy] = decoded["help_groups"]
      assert nav["title"] == "Navigation"
      assert Enum.count(nav["bindings"]) == 2

      [b1, b2] = nav["bindings"]
      assert b1["key"] == "j / k"
      assert b1["description"] == "Scroll down / up"
      assert b2["key"] == "gg / G"
      assert b2["description"] == "Top / bottom"

      assert copy["title"] == "Copy"
      assert Enum.count(copy["bindings"]) == 1
      assert hd(copy["bindings"])["key"] == "y"
    end

    test "gui_agent_chat without help data round-trips with help_visible=false", %{
      harness: harness
    } do
      data = %{
        visible: true,
        status: :idle,
        model: "claude",
        prompt: "",
        pending_approval: nil
      }

      cmd = encode_gui_agent_chat(data)
      decoded = round_trip(harness, cmd, "gui_agent_chat")

      assert decoded["type"] == "gui_agent_chat"
      assert decoded["help_visible"] == false
      assert decoded["help_groups"] == []
    end
  end

  describe "gui_gutter_separator" do
    test "round-trips gutter separator col and color", %{harness: harness} do
      cmd = <<Opcodes.gui_gutter_sep(), 4::16, 0x3F, 0x44, 0x4A>>
      decoded = round_trip(harness, cmd, "gui_gutter_separator")

      assert decoded["type"] == "gui_gutter_separator"
      assert decoded["col"] == 4
      assert decoded["r"] == 0x3F
      assert decoded["g"] == 0x44
      assert decoded["b"] == 0x4A
    end
  end

  describe "hidden GUI chrome commands" do
    test "round-trip visible false for hidden overlays", %{harness: harness} do
      alias Minga.Frontend.Adapter.GUI.BottomPanelEncoder
      alias Minga.Frontend.Adapter.GUI.Caches
      alias Minga.RenderModel.UI.BottomPanel

      {bottom_panel_cmd, _caches} =
        BottomPanelEncoder.encode(%BottomPanel{visible?: false}, Caches.new())

      {which_key_cmd, _caches} =
        WhichKeyEncoder.encode(%Minga.RenderModel.UI.WhichKey{visible: false}, Caches.new())

      cases = [
        {"gui_agent_chat", encode_gui_agent_chat(%{visible: false})},
        {"gui_completion", CompletionEncoder.encode_command(%Completion{})},
        {"gui_which_key", which_key_cmd},
        {"gui_picker", <<Opcodes.gui_picker(), 0::8>>},
        {"gui_bottom_panel", bottom_panel_cmd},
        {"gui_tool_manager", ProtocolGUI.encode_gui_tool_manager(nil)}
      ]

      for {type, command} <- cases do
        decoded = round_trip(harness, command, type)

        assert decoded["type"] == type
        assert decoded["visible"] == false
      end
    end
  end

  describe "gui_gutter" do
    test "round-trips gutter with entries", %{harness: harness} do
      alias Minga.RenderModel.Window
      alias Minga.RenderModel.Window.Gutter
      alias Minga.RenderModel.Window.GutterEntry

      model = %Window{
        window_id: 1,
        content_kind: :buffer,
        rect: {0, 0, 80, 24},
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block,
        rows: [],
        gutter: %Gutter{
          window_id: 1,
          content_row: 0,
          content_col: 5,
          content_height: 24,
          content_width: 80,
          is_active: true,
          cursor_line: 10,
          line_number_style: :hybrid,
          line_number_width: 4,
          sign_col_width: 1,
          entries: [
            %GutterEntry{buf_line: 8, display_type: :normal, sign_type: :git_added},
            %GutterEntry{buf_line: 9, display_type: :fold_start, sign_type: :none},
            %GutterEntry{buf_line: 10, display_type: :wrap_continuation, sign_type: :diag_error}
          ]
        }
      }

      cmd =
        Enum.find(WindowEncoder.encode(model), fn <<opcode::8, _rest::binary>> ->
          opcode == Opcodes.gui_gutter()
        end)

      decoded = round_trip(harness, cmd, "gui_gutter")

      assert decoded["type"] == "gui_gutter"
      assert decoded["window_id"] == 1
      assert decoded["content_col"] == 5
      assert decoded["content_height"] == 24
      assert decoded["content_width"] == 80
      assert decoded["is_active"] == true
      assert decoded["cursor_line"] == 10
      assert decoded["line_number_style"] == 0
      assert decoded["line_number_width"] == 4
      assert decoded["sign_col_width"] == 1
      assert Enum.count(decoded["entries"]) == 3

      [e1, e2, e3] = decoded["entries"]
      assert e1["buf_line"] == 8
      assert e1["display_type"] == 0
      assert e1["sign_type"] == 1
      assert e2["display_type"] == 1
      assert e2["fold_end_line"] == nil
      assert e3["display_type"] == 3
      assert e3["sign_type"] == 4
    end
  end

  describe "gui_completion visible" do
    test "round-trips visible completion with items", %{harness: harness} do
      comp = %Minga.Editing.Completion{
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

      {visible_items, selected_offset} = Minga.Editing.Completion.visible_items(comp)

      model = %Completion{
        visible?: true,
        cursor_row: 5,
        cursor_col: 0,
        selected_offset: selected_offset,
        documentation: "Defines a function.",
        items:
          Enum.map(visible_items, fn item ->
            %Completion.Item{kind: item.kind, label: item.label, detail: item.detail || ""}
          end)
      }

      cmd = CompletionEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_completion")

      assert decoded["type"] == "gui_completion"
      assert decoded["visible"] == true
      assert decoded["anchor_row"] == 5
      assert decoded["anchor_col"] == 0
      assert decoded["selected_index"] == 0
      assert Enum.count(decoded["items"]) == 2
      assert hd(decoded["items"])["label"] == "def"
      assert decoded["documentation"] == "Defines a function."
    end
  end

  describe "gui_which_key visible" do
    test "round-trips visible which-key with bindings", %{harness: harness} do
      # Build raw binary: visible=1, prefix="SPC", page=0, pageCount=2, 2 bindings
      prefix = "SPC"

      binding1 =
        <<0::8, 1::8, "f"::binary, 9::16, "Find file"::binary, 0::8>>

      binding2 =
        <<1::8, 1::8, "b"::binary, 7::16, "Buffers"::binary, 0::8>>

      cmd =
        <<0x72, 1::8, byte_size(prefix)::16, prefix::binary, 0::8, 2::8, 2::16, binding1::binary,
          binding2::binary>>

      decoded = round_trip(harness, cmd, "gui_which_key")

      assert decoded["type"] == "gui_which_key"
      assert decoded["visible"] == true
      assert decoded["prefix"] == "SPC"
      assert decoded["page"] == 0
      assert decoded["page_count"] == 2
      assert Enum.count(decoded["bindings"]) == 2

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
    test "round-trips visible picker with items", %{harness: harness} do
      # The production PickerBuilder normalizes a filtered legacy picker into
      # this wire-shaped RenderModel.UI.Picker (flags packed: marked => bit 1 =>
      # 2; query "edi" re-derives match_positions [0, 1, 2] against "editor.ex").
      # This mirrors what the old ProtocolGUI.encode_gui_picker oracle received.
      model = %PickerModel{
        visible?: true,
        title: "Find File",
        query: "edi",
        query_generation: 7,
        acknowledged_query_edit_seq: 11,
        selected_index: 0,
        filtered_count: 1,
        total_count: 2,
        marked_count: 1,
        has_preview?: false,
        items: [
          %{
            icon_color: 0x51AFEF,
            flags: 2,
            label: "editor.ex",
            description: "lib",
            annotation: "",
            match_positions: [0, 1, 2]
          }
        ],
        action_menu: nil,
        mode_prefix: ">",
        load_status: :ready
      }

      cmd = PickerEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_picker")

      assert decoded["type"] == "gui_picker"
      assert decoded["visible"] == true
      assert decoded["title"] == "Find File"
      assert decoded["query"] == "edi"
      assert decoded["query_generation"] == 7
      assert decoded["acknowledged_query_edit_seq"] == 11
      assert decoded["mode_prefix"] == ">"
      assert decoded["filtered_count"] == 1
      assert decoded["total_count"] == 2
      assert decoded["marked_count"] == 1
      assert Enum.count(decoded["items"]) == 1

      item = hd(decoded["items"])
      assert item["label"] == "editor.ex"
      assert item["description"] == "lib"
      assert item["match_positions"] == [0, 1, 2]
    end
  end

  describe "gui_picker_preview visible" do
    test "round-trips visible preview with styled lines", %{harness: harness} do
      # Line 1: 2 segments
      seg1 = <<0x51, 0xAF, 0xEF, 0x01, 4::16, "def "::binary>>
      seg2 = <<0xEC, 0xBE, 0x7B, 0x00, 5::16, "hello"::binary>>
      # Line 2: 1 segment
      seg3 = <<0xBB, 0xC2, 0xCF, 0x00, 3::16, ":ok"::binary>>

      cmd =
        <<0x7D, 1::8, 2::16, 2::8, seg1::binary, seg2::binary, 1::8, seg3::binary>>

      decoded = round_trip(harness, cmd, "gui_picker_preview")

      assert decoded["type"] == "gui_picker_preview"
      assert decoded["visible"] == true
      assert Enum.count(decoded["lines"]) == 2

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
    test "round-trips visible bottom panel with tabs and entries", %{harness: harness} do
      # Tab: type=0 (messages), name="Messages"
      tab = <<0::8, 8::8, "Messages"::binary>>

      # Content: stream_instance(4) + entry_count(2) + entries...
      # Entry: id(4) + level(1) + subsystem(1) + timestamp(4) + path_len(2) + path + text_len(2) + text
      path = "lib/editor.ex"
      text = "File opened"

      entry =
        <<42::32, 1::8, 0::8, 3661::32, byte_size(path)::16, path::binary, byte_size(text)::16,
          text::binary>>

      cmd =
        <<0x7C, 1::8, 0::8, 30::8, 0::8, 1::8, tab::binary, 7::32, 1::16, entry::binary>>

      decoded = round_trip(harness, cmd, "gui_bottom_panel")

      assert decoded["type"] == "gui_bottom_panel"
      assert decoded["visible"] == true
      assert decoded["active_tab_index"] == 0
      assert decoded["height_percent"] == 30
      assert Enum.count(decoded["tabs"]) == 1
      assert hd(decoded["tabs"])["name"] == "Messages"
      assert Enum.count(decoded["entries"]) == 1

      entry_decoded = hd(decoded["entries"])
      assert entry_decoded["id"] == 42
      assert entry_decoded["level"] == 1
      assert entry_decoded["text"] == "File opened"
    end
  end

  describe "gui_tool_manager visible" do
    test "round-trips visible tool manager with tools", %{harness: harness} do
      # Tool: name_len(1)+name, label_len(1)+label, desc_len(2)+desc,
      #       category(1)+status(1)+method(1)+lang_count(1),
      #       lang_len(1)+lang, version_len(1)+version,
      #       homepage_len(2)+homepage, provides_count(1)+provides_len(1)+provides,
      #       error_reason_len(2)+error_reason
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
          homepage::binary, 1::8, byte_size(provides)::8, provides::binary, 0::16>>

      cmd = <<0x7E, 1::8, 0::8, 0::16, 1::16, tool::binary>>

      decoded = round_trip(harness, cmd, "gui_tool_manager")

      assert decoded["type"] == "gui_tool_manager"
      assert decoded["visible"] == true
      assert decoded["filter"] == 0
      assert Enum.count(decoded["tools"]) == 1

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

    test "round-trips failed tool with error reason", %{harness: harness} do
      error = "No matching asset for darwin_arm64"

      tool =
        <<5::8, "pyrit"::binary, 6::8, "Pyrite"::binary, 4::16, "Test"::binary, 0::8, 4::8, 0::8,
          0::8, 0::8, ""::binary, 0::16, ""::binary, 0::8, byte_size(error)::16, error::binary>>

      cmd = <<0x7E, 1::8, 0::8, 0::16, 1::16, tool::binary>>
      decoded = round_trip(harness, cmd, "gui_tool_manager")

      t = hd(decoded["tools"])
      assert t["status"] == 4
      assert t["error_reason"] == "No matching asset for darwin_arm64"
    end

    test "encodes failed tool error_reason through Elixir encoder", %{harness: harness} do
      tool = %{
        name: :pyrite,
        label: "Pyrite",
        description: "Test",
        category: :lsp_server,
        status: :failed,
        method: :npm,
        languages: [],
        version: nil,
        homepage: nil,
        provides: [],
        error_reason: "No matching asset for darwin_arm64"
      }

      cmd =
        ProtocolGUI.encode_gui_tool_manager(%{
          visible: true,
          filter: :all,
          selected_index: 0,
          tools: [tool]
        })

      decoded = round_trip(harness, cmd, "gui_tool_manager")

      t = hd(decoded["tools"])
      assert t["status"] == 4
      assert t["error_reason"] == "No matching asset for darwin_arm64"
    end
  end

  describe "gui_file_tree visible" do
    test "round-trips semantic visible file tree with entries", %{harness: harness} do
      root = "/project"

      rows = [
        %Row{
          id: "/project/lib",
          path: "/project/lib",
          name: "lib",
          icon: "󱉇",
          icon_color: 0x42A5F5,
          flags: %Flags{
            directory?: true,
            expanded?: true
          },
          depth: 0,
          guides: []
        },
        %Row{
          id: "/project/lib/editor.ex",
          path: "/project/lib/editor.ex",
          name: "editor.ex",
          icon: "",
          icon_color: 0x9B59B6,
          flags: %Flags{
            active?: true,
            dirty?: true,
            last_child?: true
          },
          git_status: :modified,
          depth: 1,
          guides: [true],
          editing: %Editing{type: :rename, text: "editor_renamed.ex"}
        }
      ]

      command =
        FileTreeEncoder.encode_command(%FileTree{
          root_path: root,
          tree_width: 30,
          status: :ready,
          focused?: true,
          selected_id: "/project/lib",
          rows: rows
        })

      decoded = round_trip(harness, command, "gui_file_tree")

      assert decoded["type"] == "gui_file_tree"
      assert decoded["version"] == 2
      assert decoded["tree_state"] == 3
      assert decoded["error_reason"] == ""
      assert Bitwise.band(decoded["tree_flags"], 0x01) != 0
      assert Bitwise.band(decoded["tree_flags"], 0x02) != 0
      assert decoded["selected_id"] == "/project/lib"
      assert decoded["tree_width"] == 30
      assert decoded["root_path"] == "/project"
      assert Enum.count(decoded["entries"]) == 2

      [e1, e2] = decoded["entries"]
      assert e1["id"] == "/project/lib"
      assert e1["path"] == "/project/lib"
      assert e1["name"] == "lib"
      assert e1["relative_path"] == "lib"
      assert e1["is_dir"] == true
      assert e1["is_expanded"] == true
      assert e1["is_selected"] == true
      assert e1["is_focused"] == true
      assert e1["depth"] == 0

      assert e2["id"] == "/project/lib/editor.ex"
      assert e2["name"] == "editor.ex"
      assert e2["relative_path"] == "lib/editor.ex"
      assert e2["is_dir"] == false
      assert e2["is_active"] == true
      assert e2["is_dirty"] == true
      assert e2["is_editing"] == true
      assert e2["depth"] == 1
      assert e2["git_status"] == 1
    end
  end

  describe "gui_cursorline" do
    test "round-trips visible and hidden cursorline states", %{harness: harness} do
      decoded =
        round_trip(
          harness,
          <<Opcodes.gui_cursorline(), 12::16, 0x2C, 0x32, 0x3C>>,
          "gui_cursorline"
        )

      assert decoded["type"] == "gui_cursorline"
      assert decoded["row"] == 12
      assert decoded["r"] == 0x2C
      assert decoded["g"] == 0x32
      assert decoded["b"] == 0x3C

      decoded =
        round_trip(harness, <<Opcodes.gui_cursorline(), 0xFFFF::16, 0, 0, 0>>, "gui_cursorline")

      assert decoded["type"] == "gui_cursorline"
      assert decoded["row"] == 0xFFFF
      assert decoded["r"] == 0
      assert decoded["g"] == 0
      assert decoded["b"] == 0
    end
  end

  describe "gui_window_content" do
    test "round-trips window content with rows, selection, and diagnostics", %{harness: harness} do
      alias Minga.RenderModel.Window
      alias Minga.RenderModel.Window.{DiagnosticRange, Row, Selection, Span}

      sw = %Window{
        window_id: 7,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        full_refresh: true,
        cursor_row: 1,
        cursor_col: 3,
        cursor_shape: :beam,
        rows: [
          %Row{
            row_id: Row.stable_id(:normal, 0),
            row_type: :normal,
            buf_line: 0,
            text: "def foo do",
            content_hash: 12_345,
            spans: [
              %Span{start_col: 0, end_col: 3, fg: 0x51AFEF, bg: 0x282C34, attrs: 0x01}
            ]
          },
          %Row{
            row_id: Row.stable_id(:fold_start, 1),
            row_type: :fold_start,
            buf_line: 1,
            text: "  :ok",
            spans: [],
            content_hash: 99
          }
        ],
        selection: %Selection{type: :char, start_row: 0, start_col: 0, end_row: 0, end_col: 10},
        search_matches: [],
        diagnostic_ranges: [
          %DiagnosticRange{
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 3,
            severity: :warning
          }
        ]
      }

      cmd = WindowEncoder.encode_window_content(sw)
      decoded = round_trip(harness, cmd, "gui_window_content")

      assert decoded["type"] == "gui_window_content"
      assert decoded["window_id"] == 7
      assert decoded["full_refresh"] == true
      assert decoded["cursor_row"] == 1
      assert decoded["cursor_col"] == 3
      assert decoded["cursor_shape"] == 1
      assert Enum.count(decoded["rows"]) == 2

      [r1, r2] = decoded["rows"]
      assert r1["text"] == "def foo do"
      assert r1["row_type"] == 0
      assert r1["row_id"] == Row.stable_id(:normal, 0)
      assert r1["buf_line"] == 0
      assert Enum.count(r1["spans"]) == 1
      assert hd(r1["spans"])["fg"] == 0x51AFEF
      assert r2["row_type"] == 1
      assert r2["row_id"] == Row.stable_id(:fold_start, 1)
      assert r2["text"] == "  :ok"

      assert decoded["selection"]["type"] == 1
      assert decoded["selection"]["start_row"] == 0
      assert decoded["selection"]["end_col"] == 10
      assert decoded["diagnostic_count"] == 1
    end

    test "round-trips a large full row through the viewport delta", %{harness: harness} do
      assert_large_delta_row_round_trip(
        harness,
        &WindowEncoder.encode_viewport_delta/2,
        "gui_window_viewport_delta"
      )
    end

    test "round-trips a large full row through the rows delta", %{harness: harness} do
      assert_large_delta_row_round_trip(
        harness,
        fn window, hashes ->
          delta = Minga.RenderModel.Window.RowDelta.from_snapshots([], window.rows)
          WindowEncoder.encode_rows_delta(window, delta, hashes)
        end,
        "gui_window_rows_delta"
      )
    end

    test "round-trips rows delta with ref and full entries", %{harness: harness} do
      alias Minga.RenderModel.Window
      alias Minga.RenderModel.Window.Row
      alias Minga.RenderModel.Window.RowDelta
      alias Minga.RenderModel.Window.RowSplice

      retained = %Row{
        row_id: Row.stable_id(:normal, 0),
        row_type: :normal,
        buf_line: 0,
        text: "old",
        spans: [],
        content_hash: 11
      }

      replacement = %Row{
        row_id: Row.stable_id(:normal, 1),
        row_type: :normal,
        buf_line: 1,
        text: "new",
        spans: [],
        content_hash: 22
      }

      window = %Window{
        window_id: 7,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        full_refresh: false,
        cursor_row: 1,
        cursor_col: 3,
        cursor_shape: :beam,
        content_epoch: 42,
        scroll_left: 2,
        rows: [retained, replacement]
      }

      {:ok, delta} =
        RowDelta.new(1, 2, [RowSplice.new(0, 1, [retained, replacement])])

      {cmd, true} =
        WindowEncoder.encode_rows_delta(
          window,
          delta,
          %{retained.row_id => retained.content_hash}
        )

      decoded = round_trip(harness, cmd, "gui_window_rows_delta")

      assert decoded["type"] == "gui_window_rows_delta"
      assert decoded["window_id"] == 7
      assert decoded["content_epoch"] == 42
      assert decoded["scroll_left"] == 2

      assert [%{"start_index" => 0, "delete_count" => 1, "insert_entries" => [ref, full]}] =
               decoded["row_splices"]

      assert ref["entry_type"] == "ref"
      assert ref["row_id"] == Row.stable_id(:normal, 0)
      assert full["entry_type"] == "full"
      assert full["text"] == "new"
    end
  end

  @spec assert_large_delta_row_round_trip(
          GenServer.server(),
          (Minga.RenderModel.Window.t(), map() -> {binary(), boolean()}),
          String.t()
        ) :: :ok
  defp assert_large_delta_row_round_trip(harness, encode_delta, expected_type) do
    alias Minga.RenderModel.Window
    alias Minga.RenderModel.Window.Row

    text = String.duplicate("x", 70_000)

    row = %Row{
      row_id: Row.stable_id(:normal, 0),
      row_type: :normal,
      buf_line: 0,
      text: text,
      spans: [],
      content_hash: 1
    }

    window = %Window{
      window_id: 7,
      content_kind: :buffer,
      rect: {0, 0, 80, 20},
      full_refresh: false,
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :beam,
      content_epoch: 42,
      rows: [row]
    }

    {command, false} = encode_delta.(window, %{})
    section_id = if expected_type == "gui_window_rows_delta", do: 0x0B, else: 0x02
    rows_payload = section_payload(command, section_id)

    row_entry =
      case section_id do
        0x0B ->
          assert <<0::32, 1::32, 1::32, 0::32, 0::32, 1::32, entry::binary>> = rows_payload
          entry

        0x02 ->
          assert <<1::32, entry::binary>> = rows_payload
          entry
      end

    assert <<1::8, _row_type::8, _row_id::64, _buf_line::32, _content_hash::32, text_length::32,
             row_text::binary-size(text_length), 0::16>> = row_entry

    assert text_length == byte_size(text)
    assert text_length > 65_535
    assert byte_size(rows_payload) > 65_535
    assert row_text == text

    decoded = round_trip(harness, command, expected_type)
    assert decoded["type"] == expected_type

    if section_id == 0x0B do
      assert [%{"insert_entries" => [%{"entry_type" => "full", "text" => ^text}]}] =
               decoded["row_splices"]
    else
      assert [%{"entry_type" => "full", "text" => ^text}] = decoded["rows"]
    end

    :ok
  end

  @spec section_payload(binary(), non_neg_integer()) :: binary()
  defp section_payload(<<_opcode::8, _section_count::8, sections::binary>>, section_id) do
    find_section_payload(sections, section_id)
  end

  @spec find_section_payload(binary(), non_neg_integer()) :: binary()
  defp find_section_payload(
         <<section_id::8, length::32, payload::binary-size(length), _rest::binary>>,
         section_id
       ),
       do: payload

  defp find_section_payload(
         <<_id::8, length::32, _payload::binary-size(length), rest::binary>>,
         section_id
       ),
       do: find_section_payload(rest, section_id)
end
