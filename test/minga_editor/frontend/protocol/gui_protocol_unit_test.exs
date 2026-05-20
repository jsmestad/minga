defmodule MingaEditor.Frontend.Protocol.GUIProtocolUnitTest do
  @moduledoc """
  BEAM-side encoding tests for GUI protocol commands.
  No Swift harness needed; asserts on binary structure directly.
  """
  use ExUnit.Case, async: true

  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary
  alias MingaEditor.Session.ChromeState.WorkspaceSummary

  describe "encode_gui_tab_bar/1 with group_id" do
    test "tab entry includes group_id in wire format" do
      tab = %Tab{id: 1, kind: :file, label: "a.ex", group_id: 3}
      tb = %TabBar{tabs: [tab], active_id: 1, next_id: 2}

      <<0x71, _active_index::8, _tab_count::8, _flags::8, _tab_id::32, group_id::16,
        _rest::binary>> = ProtocolGUI.encode_gui_tab_bar(tb)

      assert group_id == 3
    end

    test "default group_id encodes as 0" do
      tab = %Tab{id: 1, kind: :file, label: "a.ex"}
      tb = %TabBar{tabs: [tab], active_id: 1, next_id: 2}

      <<0x71, _active_index::8, _tab_count::8, _flags::8, _tab_id::32, group_id::16,
        _rest::binary>> = ProtocolGUI.encode_gui_tab_bar(tb)

      assert group_id == 0
    end

    test "multiple visible tabs each carry their own group_id" do
      tab1 = %Tab{id: 1, kind: :file, label: "a.ex", group_id: 5}
      tab2 = %Tab{id: 2, kind: :file, label: "b.ex", group_id: 5}
      tb = %TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}

      binary = ProtocolGUI.encode_gui_tab_bar(tb)
      <<0x71, _::8, 2::8, rest::binary>> = binary

      <<_flags1::8, _id1::32, gid1::16, icon1_len::8, _icon1::binary-size(icon1_len),
        label1_len::16, _label1::binary-size(label1_len), rest2::binary>> = rest

      <<_flags2::8, _id2::32, gid2::16, _rest3::binary>> = rest2

      assert gid1 == 5
      assert gid2 == 5
    end

    test "uses 255 active index when the active tab is hidden from visible tabs" do
      chrome_state = %ChromeState{
        workspaces: [
          workspace_summary(id: 0, kind: :manual, label: "Files", icon: "folder"),
          workspace_summary(id: 1, kind: :agent, label: "Agent", icon: "cpu")
        ],
        visible_tabs: [
          TabSummary.new(
            id: 1,
            workspace_id: 1,
            kind: :file,
            label: "agent.ex",
            path: "/tmp/agent.ex",
            icon: "A",
            dirty?: false,
            draft_state: :none,
            attention?: false
          )
        ],
        mode: :agent,
        active_workspace_id: 1,
        active_tab_id: 99,
        background_count: 0,
        attention_count: 0,
        draft_count: 0,
        conflict_count: 0
      }

      <<0x71, active_index::8, tab_count::8, flags::8, _id::32, _workspace::16, icon_len::8,
        _icon::binary-size(icon_len), label_len::16, _label::binary-size(label_len)>> =
        ProtocolGUI.encode_gui_tab_bar(chrome_state)

      assert active_index == 255
      assert tab_count == 1
      assert Bitwise.band(flags, 0x01) == 0
    end

    test "agent tabs and file tabs from other workspaces are omitted" do
      tab1 = %Tab{id: 1, kind: :file, label: "a.ex", group_id: 0}
      tab2 = %Tab{id: 2, kind: :agent, label: "Agent", group_id: 7}
      tab3 = %Tab{id: 3, kind: :file, label: "b.ex", group_id: 7}
      tb = %TabBar{tabs: [tab1, tab2, tab3], active_id: 2, next_id: 4}

      <<0x71, active_index::8, 1::8, rest::binary>> = ProtocolGUI.encode_gui_tab_bar(tb)
      <<_flags::8, id::32, _rest::binary>> = rest

      assert active_index == 255
      assert id == 3
    end
  end

  describe "encode_gui_workspaces/1" do
    test "encodes header with group count" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add_workspace(tb, "Agent")

      <<0x86, _active::16, count::8, _rest::binary>> =
        ProtocolGUI.encode_gui_workspaces(tb)

      assert count == 1
    end

    test "workspace encodes with correct color and no kind byte" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, group} = TabBar.add_workspace(tb, "Agent")

      binary = ProtocolGUI.encode_gui_workspaces(tb)
      <<0x86, _active::16, 1::8, rest::binary>> = binary

      # No kind byte: id(2) + status(1) + r(1) + g(1) + b(1) + tab_count(2) + label_len(1) + label + icon_len(1) + icon
      <<agent_id::16, agent_status::8, r::8, g::8, b::8, _tc::16, label_len::8,
        label::binary-size(label_len), icon_len::8, icon::binary-size(icon_len), _rest2::binary>> =
        rest

      assert agent_id == group.id
      assert agent_status == 0

      expected_r = Bitwise.bsr(Bitwise.band(group.color, 0xFF0000), 16)
      expected_g = Bitwise.bsr(Bitwise.band(group.color, 0x00FF00), 8)
      expected_b = Bitwise.band(group.color, 0x0000FF)
      assert r == expected_r
      assert g == expected_g
      assert b == expected_b
      assert label == "Agent"
      assert icon == "cpu"
    end

    test "icon field is encoded" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, group} = TabBar.add_workspace(tb, "Test")
      tb = TabBar.update_workspace(tb, group.id, &Workspace.set_icon(&1, "star"))

      binary = ProtocolGUI.encode_gui_workspaces(tb)

      <<0x86, _active::16, 1::8, _id::16, _status::8, _r::8, _g::8, _b::8, _tc::16, label_len::8,
        _label::binary-size(label_len), icon_len::8, icon::binary-size(icon_len), _rest::binary>> =
        binary

      assert icon == "star"
    end

    test "ChromeState encoding keeps manual workspace out of legacy workspaces" do
      chrome_state = %ChromeState{
        workspaces: [
          workspace_summary(id: 0, kind: :manual, label: "Files", icon: "folder"),
          workspace_summary(id: 1, kind: :agent, label: "Agent", icon: "cpu")
        ],
        visible_tabs: [],
        mode: :editor,
        active_workspace_id: 0,
        active_tab_id: nil,
        background_count: 0,
        attention_count: 0,
        draft_count: 0,
        conflict_count: 0
      }

      <<0x86, 0::16, 1::8, id::16, _rest::binary>> =
        ProtocolGUI.encode_gui_workspaces(chrome_state)

      assert id == 1
    end
  end

  defp workspace_summary(attrs) do
    WorkspaceSummary.new(
      id: Keyword.fetch!(attrs, :id),
      kind: Keyword.fetch!(attrs, :kind),
      label: Keyword.fetch!(attrs, :label),
      icon: Keyword.fetch!(attrs, :icon),
      color: Keyword.get(attrs, :color, 0),
      status: Keyword.get(attrs, :status, :idle),
      attention?: false,
      tab_count: 0,
      draft_count: 0,
      conflict_count: 0,
      running_background_count: 0,
      closeable?: Keyword.get(attrs, :kind) == :agent
    )
  end

  describe "decode_gui_action for gutter fold actions" do
    test "decodes fold toggle at line" do
      assert {:ok, {:fold_toggle_at_line, 7, 42}} ==
               ProtocolGUI.decode_gui_action(0x41, <<7::16, 42::32>>)

      assert :error == ProtocolGUI.decode_gui_action(0x41, <<42::32>>)
    end
  end

  describe "decode_gui_action for context menu actions" do
    test "decodes file tree open in split" do
      assert {:ok, {:file_tree_open_in_split, 9}} ==
               ProtocolGUI.decode_gui_action(0x3D, <<9::16>>)
    end

    test "decodes tab copy path" do
      assert {:ok, {:tab_copy_path, 42}} == ProtocolGUI.decode_gui_action(0x3E, <<42::32>>)
    end

    test "decodes hover open action" do
      assert {:ok, :hover_open_action} == ProtocolGUI.decode_gui_action(0x3F, <<>>)
    end
  end

  describe "encode_gui_hover_action/1" do
    test "encodes visible action with length prefix" do
      popup = %MingaEditor.HoverPopup{
        content_lines: [{[{"Open", :bold}], :text}],
        anchor_row: 1,
        anchor_col: 2,
        open_action: :goto_definition
      }

      binary = ProtocolGUI.encode_gui_hover_action(popup)

      assert <<0x96, payload_len::16, 1::8, action_len::16, action::binary>> = binary
      assert payload_len == 1 + 2 + action_len
      assert action == "goto_definition"
    end
  end

  describe "decode_gui_action for workspace actions" do
    test "decodes workspace rename" do
      name = "My Research"
      payload = <<42::16, byte_size(name)::16, name::binary>>

      assert {:ok, {:workspace_rename, 42, "My Research"}} ==
               ProtocolGUI.decode_gui_action(0x1F, payload)
    end

    test "decodes workspace set icon" do
      icon = "brain"
      payload = <<7::16, byte_size(icon)::8, icon::binary>>

      assert {:ok, {:workspace_set_icon, 7, "brain"}} ==
               ProtocolGUI.decode_gui_action(0x20, payload)
    end

    test "decodes workspace close" do
      payload = <<3::16>>
      assert {:ok, {:workspace_close, 3}} == ProtocolGUI.decode_gui_action(0x21, payload)
    end
  end

  # ── Clipboard write (forward-compatible 0x90+ format) ──────────────────

  describe "encode_clipboard_write/2" do
    test "encodes general pasteboard write with length prefix" do
      binary = ProtocolGUI.encode_clipboard_write("hello")

      # Format: opcode(1) + payload_length(2) + target(1) + text_len(2) + text
      assert <<0x90, payload_len::16, 0::8, text_len::16, text::binary>> = binary
      assert text == "hello"
      assert text_len == 5
      assert payload_len == 1 + 2 + 5
    end

    test "encodes find pasteboard write" do
      binary = ProtocolGUI.encode_clipboard_write("search", :find)

      assert <<0x90, _payload_len::16, 1::8, text_len::16, text::binary>> = binary
      assert text == "search"
      assert text_len == 6
    end

    test "encodes empty text" do
      binary = ProtocolGUI.encode_clipboard_write("")

      assert <<0x90, payload_len::16, 0::8, 0::16>> = binary
      assert payload_len == 3
    end

    test "encodes unicode text" do
      binary = ProtocolGUI.encode_clipboard_write("日本語")

      assert <<0x90, _payload_len::16, 0::8, text_len::16, text::binary>> = binary
      assert text == "日本語"
      assert text_len == byte_size("日本語")
    end

    test "forward-compatible: starts with 0x90 and length prefix is skippable" do
      binary = ProtocolGUI.encode_clipboard_write("test")

      # Verify a decoder that doesn't know 0x90 can still skip it:
      # read opcode (1 byte), read payload_len (2 bytes), skip payload_len bytes
      <<0x90, payload_len::16, _payload::binary-size(payload_len)>> = binary
    end
  end

  # ── Find Pasteboard gui_action decode ────────────────────────────────────

  describe "decode_gui_action for find_pasteboard_search" do
    test "decodes forward search" do
      text = "hello"
      payload = <<0::8, byte_size(text)::16, text::binary>>

      assert {:ok, {:find_pasteboard_search, "hello", 0}} ==
               ProtocolGUI.decode_gui_action(0x24, payload)
    end

    test "decodes backward search" do
      text = "world"
      payload = <<1::8, byte_size(text)::16, text::binary>>

      assert {:ok, {:find_pasteboard_search, "world", 1}} ==
               ProtocolGUI.decode_gui_action(0x24, payload)
    end
  end

  describe "encode_gui_indent_guides/1" do
    test "encodes guides with correct opcode, window_id, and columns" do
      data = %{
        window_id: 1,
        tab_width: 2,
        active_guide_col: 4,
        guide_cols: [2, 4],
        line_indent_levels: [1, 2, 2, 1, 0]
      }

      binary = ProtocolGUI.encode_gui_indent_guides(data)

      <<0x91, payload_len::16, win_id::16, tw::8, active_col::16, count::8, rest::binary>> =
        binary

      assert win_id == 1
      assert tw == 2
      assert active_col == 4
      assert count == 2
      # 6 (header) + 2*2 (guide cols) + 2 (line_count) + 5 (levels)
      assert payload_len == 6 + 2 * 2 + 2 + 5

      <<col1::16, col2::16, line_count::16, levels::binary>> = rest
      assert col1 == 2
      assert col2 == 4
      assert line_count == 5
      assert levels == <<1, 2, 2, 1, 0>>
    end

    test "encodes empty guide list" do
      binary = ProtocolGUI.encode_gui_indent_guides_empty(3)

      <<0x91, payload_len::16, win_id::16, _tw::8, active_col::16, count::8>> = binary

      assert win_id == 3
      assert active_col == 0xFFFF
      assert count == 0
      assert payload_len == 6
    end

    test "guide columns round-trip through binary encoding" do
      cols = [4, 8, 12, 16]

      data = %{
        window_id: 2,
        tab_width: 4,
        active_guide_col: 8,
        guide_cols: cols,
        line_indent_levels: [2, 4, 4, 3, 1]
      }

      binary = ProtocolGUI.encode_gui_indent_guides(data)

      <<0x91, _len::16, _win::16, _tw::8, _active::16, count::8, rest::binary>> = binary

      col_bytes_len = count * 2
      <<col_data::binary-size(col_bytes_len), line_count::16, levels::binary>> = rest

      decoded_cols =
        for <<col::16 <- col_data>>, do: col

      assert count == 4
      assert decoded_cols == cols
      assert line_count == 5
      assert levels == <<2, 4, 4, 3, 1>>
    end

    test "indent levels above 255 are clamped to fit uint8 wire format" do
      data = %{
        window_id: 1,
        tab_width: 2,
        active_guide_col: 0xFFFF,
        guide_cols: [2],
        line_indent_levels: [300, 0, 256, 255]
      }

      binary = ProtocolGUI.encode_gui_indent_guides(data)

      <<0x91, _len::16, _win::16, _tw::8, _active::16, _count::8, _col::16, line_count::16,
        levels::binary>> = binary

      assert line_count == 4
      assert levels == <<255, 0, 255, 255>>
    end
  end

  describe "encode_gui_line_spacing/1" do
    test "encodes spacing 1.2 as 120" do
      binary = ProtocolGUI.encode_gui_line_spacing(1.2)

      <<0x92, payload_len::16, spacing_encoded::16>> = binary

      assert payload_len == 2
      assert spacing_encoded == 120
    end

    test "encodes spacing 1.0 as 100" do
      <<0x92, _::16, spacing_encoded::16>> = ProtocolGUI.encode_gui_line_spacing(1.0)
      assert spacing_encoded == 100
    end

    test "encodes spacing 1.5 as 150" do
      <<0x92, _::16, spacing_encoded::16>> = ProtocolGUI.encode_gui_line_spacing(1.5)
      assert spacing_encoded == 150
    end

    test "forward-compatible: opcode + length prefix is skippable" do
      binary = ProtocolGUI.encode_gui_line_spacing(1.2)
      <<0x92, payload_len::16, _payload::binary-size(payload_len)>> = binary
    end
  end

  describe "encode_gui_cursor_animation/1" do
    test "encodes enabled cursor animation" do
      assert <<0x95, 1::16, 1::8>> = ProtocolGUI.encode_gui_cursor_animation(true)
    end

    test "encodes disabled cursor animation" do
      assert <<0x95, 1::16, 0::8>> = ProtocolGUI.encode_gui_cursor_animation(false)
    end
  end

  describe "encode_gui_status_bar/1 background subagents" do
    test "encodes background subagent count and label in buffer agent section" do
      binary = ProtocolGUI.encode_gui_status_bar({:buffer, status_data()})
      sections = status_sections(binary)

      <<agent_status::8, count::16, label_len::16, label::binary-size(label_len)>> =
        Map.fetch!(sections, 0x09)

      assert agent_status == 1
      assert count == 2
      assert label == "session-3: tests"
    end

    test "omits modeline segment section when no GUI modeline data is attached" do
      binary = ProtocolGUI.encode_gui_status_bar({:buffer, status_data()})
      sections = status_sections(binary)

      refute Map.has_key?(sections, 0x0B)
    end

    test "encodes explicit empty modeline segment section" do
      data =
        Map.put(status_data(), :modeline_segments, %{
          left: [],
          right: []
        })

      binary = ProtocolGUI.encode_gui_status_bar({:buffer, data})
      sections = status_sections(binary)

      assert <<2, 0::16, 0::16>> = Map.fetch!(sections, 0x0B)
    end

    test "encodes configured modeline segment section" do
      data =
        Map.put(status_data(), :modeline_segments, %{
          left: [{:mode, " NORMAL ", 0xBBC2CF, 0x51AFEF, [bold: true], nil}],
          right: [{:filetype, " Elixir ", 0xC678DD, 0x282C34, [], :set_language}]
        })

      binary = ProtocolGUI.encode_gui_status_bar({:buffer, data})
      sections = status_sections(binary)

      <<2::8, 1::16, 1::16, segments::binary>> = Map.fetch!(sections, 0x0B)
      {left, rest} = take_modeline_segment(segments)
      {right, ""} = take_modeline_segment(rest)

      assert left.name == "mode"
      assert left.fg == 0xBBC2CF
      assert left.bg == 0x51AFEF
      assert left.attrs == 0x01
      assert left.text == " NORMAL "
      assert left.target == ""
      assert right.name == "filetype"
      assert right.fg == 0xC678DD
      assert right.bg == 0x282C34
      assert right.attrs == 0x00
      assert right.text == " Elixir "
      assert right.target == "set_language"
    end

    test "bounds oversized modeline segment text to the 16-bit section limit" do
      data =
        Map.put(status_data(), :modeline_segments, %{
          left: [{:custom, String.duplicate("x", 70_000), 0xBBC2CF, 0x51AFEF, [], nil}],
          right: []
        })

      binary = ProtocolGUI.encode_gui_status_bar({:buffer, data})
      sections = status_sections(binary)
      payload = Map.fetch!(sections, 0x0B)

      assert byte_size(payload) <= 65_535

      <<2::8, 1::16, 0::16, segments::binary>> = payload
      {segment, ""} = take_modeline_segment(segments)

      assert byte_size(segment.text) <= 65_512
    end

    test "drops trailing modeline segments when the section would overflow" do
      tiny_segment = {:custom, "x", 0xBBC2CF, 0x51AFEF, [], nil}

      data =
        Map.put(status_data(), :modeline_segments, %{
          left: List.duplicate(tiny_segment, 70_000),
          right: []
        })

      binary = ProtocolGUI.encode_gui_status_bar({:buffer, data})
      sections = status_sections(binary)
      payload = Map.fetch!(sections, 0x0B)
      <<2::8, left_count::16, 0::16, _segments::binary>> = payload

      assert byte_size(payload) <= 65_535
      assert left_count == 128
    end

    test "caps total modeline segments across both sides" do
      tiny_segment = {:custom, "x", 0xBBC2CF, 0x51AFEF, [], nil}

      data =
        Map.put(status_data(), :modeline_segments, %{
          left: List.duplicate(tiny_segment, 100),
          right: List.duplicate(tiny_segment, 100)
        })

      binary = ProtocolGUI.encode_gui_status_bar({:buffer, data})
      payload = binary |> status_sections() |> Map.fetch!(0x0B)
      <<2::8, left_count::16, right_count::16, _segments::binary>> = payload

      assert left_count == 100
      assert right_count == 28
    end

    test "does not truncate oversized modeline command targets" do
      first_segment = {:custom, String.duplicate("x", 65_487), 0xBBC2CF, 0x51AFEF, [], nil}
      clickable_segment = {:filetype, "Y", 0xBBC2CF, 0x51AFEF, [], :set_language}

      data =
        Map.put(status_data(), :modeline_segments, %{
          left: [first_segment, clickable_segment],
          right: []
        })

      binary = ProtocolGUI.encode_gui_status_bar({:buffer, data})
      payload = binary |> status_sections() |> Map.fetch!(0x0B)
      <<2::8, 2::16, 0::16, segments::binary>> = payload
      {_first, rest} = take_modeline_segment(segments)
      {second, ""} = take_modeline_segment(rest)

      assert second.text == "Y"
      assert second.target == ""
    end

    test "sanitizes invalid UTF-8 modeline text before encoding" do
      data =
        Map.put(status_data(), :modeline_segments, %{
          left: [{:custom, <<"BAD", 0xFF>>, 0xBBC2CF, 0x51AFEF, [], nil}],
          right: []
        })

      binary = ProtocolGUI.encode_gui_status_bar({:buffer, data})
      payload = binary |> status_sections() |> Map.fetch!(0x0B)
      <<2::8, 1::16, 0::16, segments::binary>> = payload
      {segment, ""} = take_modeline_segment(segments)

      assert segment.text == "BAD"
    end

    test "encodes background subagent count and label in agent variant" do
      data =
        Map.merge(status_data(), %{
          model_name: "Agent",
          session_status: :thinking,
          message_count: 4
        })

      binary = ProtocolGUI.encode_gui_status_bar({:agent, data})
      sections = status_sections(binary)

      <<model_len::8, _model::binary-size(model_len), 4::32, session_status::8, agent_status::8,
        count::16, label_len::16, label::binary-size(label_len)>> = Map.fetch!(sections, 0x09)

      assert session_status == 1
      assert agent_status == 1
      assert count == 2
      assert label == "session-3: tests"
    end
  end

  defp status_data do
    %{
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      cursor_line: 0,
      cursor_col: 0,
      line_count: 1,
      file_name: "test.ex",
      filetype: :elixir,
      dirty: false,
      git_branch: nil,
      git_diff_summary: nil,
      diagnostic_counts: nil,
      diagnostic_hint: nil,
      lsp_status: :none,
      parser_status: :available,
      buf_index: 1,
      buf_count: 1,
      macro_recording: false,
      agent_status: :thinking,
      agent_theme_colors: nil,
      background_subagent_count: 2,
      active_background_subagent_label: "session-3: tests",
      status_msg: nil
    }
  end

  defp status_sections(<<0x76, count::8, rest::binary>>) do
    parse_status_sections(rest, count, %{})
  end

  defp take_modeline_segment(
         <<name_len::8, name::binary-size(name_len), fg::24, bg::24, attrs::8, text_len::16,
           text::binary-size(text_len), target_len::16, target::binary-size(target_len),
           rest::binary>>
       ) do
    {%{name: name, fg: fg, bg: bg, attrs: attrs, text: text, target: target}, rest}
  end

  defp parse_status_sections(rest, 0, acc) do
    assert rest == ""
    acc
  end

  defp parse_status_sections(
         <<id::8, len::16, payload::binary-size(len), rest::binary>>,
         count,
         acc
       ) do
    parse_status_sections(rest, count - 1, Map.put(acc, id, payload))
  end
end
