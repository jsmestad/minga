defmodule Minga.Frontend.Protocol.GUI do
  @moduledoc """
  Binary protocol encoder/decoder for GUI chrome commands (BEAM → Swift/GTK).

  This module handles the structured data protocol for native GUI elements:
  tab bars, file trees, which-key popups, completion menus, breadcrumbs,
  status bars, pickers, agent chat, and theme colors. These are separate
  from the TUI cell-grid rendering commands in `Minga.Frontend.Protocol`.

  ## GUI Chrome Commands (BEAM → Frontend)

  Contiguous range 0x70-0x7F for easy classification by frontends.

  | Opcode | Name            | Description                    |
  |--------|-----------------|--------------------------------|
  | 0x70   | gui_file_tree   | File tree entries              |
  | 0x71   | gui_tab_bar     | Tab bar with tab entries       |
  | 0x72   | gui_which_key   | Which-key popup bindings       |
  | 0x73   | gui_completion  | Completion popup items         |
  | 0x74   | gui_theme       | Theme color slots              |
  | 0x75   | gui_breadcrumb  | Path breadcrumb segments       |
  | 0x76   | gui_status_bar  | Status bar data                |
  | 0x77   | gui_picker      | Fuzzy picker items             |
  | 0x78   | gui_agent_chat  | Agent conversation view        |
  | 0x79   | gui_gutter_sep  | Gutter separator col + color   |
  | 0x7A   | gui_cursorline  | Cursorline row + bg color      |
  | 0x7B   | gui_gutter      | Structured gutter data         |
  | 0x7C   | gui_bottom_panel| Bottom panel container state   |
  | 0x7D   | gui_picker_preview | Picker preview content      |
  | 0x7E   | gui_tool_manager| Tool manager panel           |
  | 0x7F   | gui_minibuffer  | Native minibuffer + candidates|
  | 0x81   | gui_hover_popup | Native hover tooltip popup    |
  | 0x82   | gui_signature_help | Signature help popup       |
  | 0x83   | gui_float_popup | Float popup window            |
  | 0x84   | gui_split_separators | Split pane separator lines |
  | 0x85   | gui_git_status       | Git status panel data      |
  | 0x86   | gui_agent_groups    | Workspace indicator + list |
  | 0x87   | gui_board           | Board card grid state      |

  ## GUI Actions (Frontend → BEAM)

  | Sub-opcode | Name                 |
  |------------|----------------------|
  | 0x01       | select_tab           |
  | 0x02       | close_tab            |
  | 0x03       | file_tree_click      |
  | 0x04       | file_tree_toggle     |
  | 0x05       | completion_select    |
  | 0x06       | breadcrumb_click     |
  | 0x07       | toggle_panel         |
  | 0x08       | new_tab              |
  | 0x09       | panel_switch_tab     |
  | 0x0A       | panel_dismiss        |
  | 0x0B       | panel_resize         |
  | 0x0C       | open_file            |
  | 0x0D       | file_tree_new_file   |
  | 0x0E       | file_tree_new_folder |
  | 0x0F       | file_tree_collapse_all |
  | 0x10       | file_tree_refresh    |
  | 0x11       | tool_install         |
  | 0x12       | tool_uninstall       |
  | 0x13       | tool_update          |
  | 0x14       | tool_dismiss         |
  | 0x15       | agent_tool_toggle    |
  | 0x16       | execute_command      |
  | 0x17       | minibuffer_select    |
  | 0x18       | git_stage_file       |
  | 0x19       | git_unstage_file     |
  | 0x1A       | git_discard_file     |
  | 0x1B       | git_stage_all        |
  | 0x1C       | git_unstage_all      |
  | 0x1D       | git_commit           |
  | 0x1E       | git_open_file        |
  | 0x1F       | agent_group_rename     |
  | 0x20       | agent_group_set_icon   |
  | 0x21       | agent_group_close      |

  """

  import Bitwise

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.MinibufferData
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Language.Filetype
  alias Minga.UI.Devicon
  alias Minga.UI.Theme.Slots

  # ── GUI chrome opcodes (BEAM → Frontend) ──
  # Contiguous range 0x70-0x7F for easy range-check classification.

  @op_gui_file_tree 0x70
  @op_gui_tab_bar 0x71
  @op_gui_which_key 0x72
  @op_gui_completion 0x73
  @op_gui_theme 0x74
  @op_gui_breadcrumb 0x75
  @op_gui_status_bar 0x76
  @op_gui_picker 0x77
  @op_gui_agent_chat 0x78
  @op_gui_gutter_separator 0x79
  @op_gui_cursorline 0x7A
  @op_gui_gutter 0x7B
  @op_gui_bottom_panel 0x7C
  @op_gui_picker_preview 0x7D
  @op_gui_tool_manager 0x7E
  @op_gui_minibuffer 0x7F
  # 0x80 is gui_window_content (in gui_window_content.ex)
  @op_gui_hover_popup 0x81
  @op_gui_signature_help 0x82
  @op_gui_float_popup 0x83
  @op_gui_split_separators 0x84
  @op_gui_git_status 0x85
  @op_gui_agent_groups 0x86
  @op_gui_board 0x87

  # ── Forward-compatible opcodes (0x90+, include 2-byte length prefix) ──
  # New opcodes >= 0x90 start with: opcode(1) + payload_length(2) + payload.
  # Old frontends skip unknown 0x90+ opcodes by reading the length and
  # advancing, instead of crashing. See ProtocolDecoder.swift default case.

  @op_clipboard_write 0x90

  # ── GUI action sub-opcodes (Frontend → BEAM) ──

  @gui_action_select_tab 0x01
  @gui_action_close_tab 0x02
  @gui_action_file_tree_click 0x03
  @gui_action_file_tree_toggle 0x04
  @gui_action_completion_select 0x05
  @gui_action_breadcrumb_click 0x06
  @gui_action_toggle_panel 0x07
  @gui_action_new_tab 0x08
  @gui_action_panel_switch_tab 0x09
  @gui_action_panel_dismiss 0x0A
  @gui_action_panel_resize 0x0B
  @gui_action_open_file 0x0C
  @gui_action_file_tree_new_file 0x0D
  @gui_action_file_tree_new_folder 0x0E
  @gui_action_file_tree_collapse_all 0x0F
  @gui_action_file_tree_refresh 0x10
  @gui_action_tool_install 0x11
  @gui_action_tool_uninstall 0x12
  @gui_action_tool_update 0x13
  @gui_action_tool_dismiss 0x14
  @gui_action_agent_tool_toggle 0x15
  @gui_action_execute_command 0x16
  @gui_action_minibuffer_select 0x17

  @gui_action_git_stage_file 0x18
  @gui_action_git_unstage_file 0x19
  @gui_action_git_discard_file 0x1A
  @gui_action_git_stage_all 0x1B
  @gui_action_git_unstage_all 0x1C
  @gui_action_git_commit 0x1D
  @gui_action_git_open_file 0x1E
  @gui_action_agent_group_rename 0x1F
  @gui_action_agent_group_set_icon 0x20
  @gui_action_agent_group_close 0x21
  @gui_action_space_leader_chord 0x22
  @gui_action_space_leader_retract 0x23
  @gui_action_find_pasteboard_search 0x24
  @gui_action_board_select_card 0x25
  @gui_action_board_close_card 0x26

  # ── Types ──

  @typedoc "A semantic GUI action from the Swift/GTK frontend."
  @type gui_action ::
          {:select_tab, id :: pos_integer()}
          | {:close_tab, id :: pos_integer()}
          | {:file_tree_click, index :: non_neg_integer()}
          | {:file_tree_toggle, index :: non_neg_integer()}
          | {:completion_select, index :: non_neg_integer()}
          | {:breadcrumb_click, segment_index :: non_neg_integer()}
          | {:toggle_panel, panel :: non_neg_integer()}
          | :new_tab
          | {:panel_switch_tab, tab_index :: non_neg_integer()}
          | :panel_dismiss
          | {:panel_resize, height_percent :: non_neg_integer()}
          | {:open_file, path :: String.t()}
          | :file_tree_new_file
          | :file_tree_new_folder
          | :file_tree_collapse_all
          | :file_tree_refresh
          | {:tool_install, name :: String.t()}
          | {:tool_uninstall, name :: String.t()}
          | {:tool_update, name :: String.t()}
          | :tool_dismiss
          | {:agent_tool_toggle, message_index :: non_neg_integer()}
          | {:execute_command, name :: String.t()}
          | {:minibuffer_select, candidate_index :: non_neg_integer()}
          | {:git_stage_file, path :: String.t()}
          | {:git_unstage_file, path :: String.t()}
          | {:git_discard_file, path :: String.t()}
          | :git_stage_all
          | :git_unstage_all
          | {:git_commit, message :: String.t()}
          | {:git_open_file, path :: String.t()}
          | {:agent_group_rename, id :: non_neg_integer(), name :: String.t()}
          | {:agent_group_set_icon, id :: non_neg_integer(), icon :: String.t()}
          | {:agent_group_close, id :: non_neg_integer()}
          | {:space_leader_chord, codepoint :: non_neg_integer(), modifiers :: non_neg_integer()}
          | {:space_leader_retract, codepoint :: non_neg_integer(),
             modifiers :: non_neg_integer()}
          | {:find_pasteboard_search, text :: String.t(), direction :: non_neg_integer()}
          | {:board_select_card, card_id :: pos_integer()}
          | {:board_close_card, card_id :: pos_integer()}

  # ═══════════════════════════════════════════════════════════════════════════
  # Encoding (BEAM → Frontend)
  # ═══════════════════════════════════════════════════════════════════════════

  # ── Cursorline ──

  @doc """
  Encodes a gui_cursorline command.

  Sends the cursor screen row and cursorline background color to the GUI
  frontend so it can draw the highlight as a native Metal quad instead of
  a full-width space fill draw.

  `row` is the screen row (0-indexed). `bg_rgb` is a 24-bit RGB color value.
  Pass `row = 0xFFFF` and `bg_rgb = 0` to indicate no cursorline (inactive
  window or cursorline disabled).
  """
  @spec encode_gui_cursorline(non_neg_integer(), non_neg_integer()) :: binary()
  def encode_gui_cursorline(row, bg_rgb)
      when is_integer(row) and is_integer(bg_rgb) do
    r = bg_rgb >>> 16 &&& 0xFF
    g = bg_rgb >>> 8 &&& 0xFF
    b = bg_rgb &&& 0xFF
    <<@op_gui_cursorline, row::16, r::8, g::8, b::8>>
  end

  # ── Gutter ──

  @typedoc "Line number display style for the GUI gutter."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "Sign type for the gutter sign column."
  @type sign_type ::
          :none
          | :git_added
          | :git_modified
          | :git_deleted
          | :diag_error
          | :diag_warning
          | :diag_info
          | :diag_hint
          | :annotation

  @typedoc "Display type for a gutter row."
  @type display_type :: :normal | :fold_start | :fold_continuation | :wrap_continuation

  @typedoc """
  A single gutter entry for one visible line.

  When `sign_type` is `:annotation`, `sign_fg` and `sign_text` carry the
  annotation icon's color and text. For all other sign types these fields
  are absent or ignored.
  """
  @type gutter_entry :: %{
          required(:buf_line) => non_neg_integer(),
          required(:display_type) => display_type(),
          required(:sign_type) => sign_type(),
          optional(:sign_fg) => non_neg_integer(),
          optional(:sign_text) => String.t()
        }

  @typedoc "Gutter data for a single window."
  @type gutter_data :: %{
          window_id: non_neg_integer(),
          content_row: non_neg_integer(),
          content_col: non_neg_integer(),
          content_height: non_neg_integer(),
          is_active: boolean(),
          cursor_line: non_neg_integer(),
          line_number_style: line_number_style(),
          line_number_width: non_neg_integer(),
          sign_col_width: non_neg_integer(),
          entries: [gutter_entry()]
        }

  @doc """
  Encodes a gui_gutter command for one window.

  One message is sent per window (not batched). Each message includes
  the window's screen position so the GUI knows where to render.

  Wire format:
    opcode(1) + window_id(2) + content_row(2) + content_col(2) + content_height(2)
    + is_active(1) + cursor_line(4) + line_number_style(1)
    + line_number_width(1) + sign_col_width(1) + line_count(2) + entries...

  Per entry:
    buf_line(4) + display_type(1) + sign_type(1)
  """
  @spec encode_gui_gutter(gutter_data()) :: binary()
  def encode_gui_gutter(%{
        window_id: window_id,
        content_row: row,
        content_col: col,
        content_height: height,
        is_active: active,
        cursor_line: cursor_line,
        line_number_style: style,
        line_number_width: ln_width,
        sign_col_width: sign_width,
        entries: entries
      }) do
    style_byte = encode_line_number_style(style)
    count = length(entries)
    active_byte = if active, do: 1, else: 0

    entry_binaries =
      Enum.map(entries, fn entry ->
        base =
          <<entry.buf_line::32, encode_display_type(entry.display_type)::8,
            encode_sign_type(entry.sign_type)::8>>

        case entry.sign_type do
          :annotation ->
            fg = Map.get(entry, :sign_fg, 0)
            text = Map.get(entry, :sign_text, "")
            text_len = byte_size(text)
            fg_r = fg >>> 16 &&& 0xFF
            fg_g = fg >>> 8 &&& 0xFF
            fg_b = fg &&& 0xFF
            <<base::binary, fg_r::8, fg_g::8, fg_b::8, text_len::8, text::binary>>

          _ ->
            base
        end
      end)

    IO.iodata_to_binary([
      <<@op_gui_gutter, window_id::16, row::16, col::16, height::16, active_byte::8,
        cursor_line::32, style_byte::8, ln_width::8, sign_width::8, count::16>>
      | entry_binaries
    ])
  end

  @spec encode_line_number_style(line_number_style()) :: non_neg_integer()
  defp encode_line_number_style(:hybrid), do: 0
  defp encode_line_number_style(:absolute), do: 1
  defp encode_line_number_style(:relative), do: 2
  defp encode_line_number_style(:none), do: 3

  @spec encode_display_type(display_type()) :: non_neg_integer()
  defp encode_display_type(:normal), do: 0
  defp encode_display_type(:fold_start), do: 1
  defp encode_display_type(:fold_continuation), do: 2
  defp encode_display_type(:wrap_continuation), do: 3

  @spec encode_sign_type(sign_type()) :: non_neg_integer()
  defp encode_sign_type(:none), do: 0
  defp encode_sign_type(:git_added), do: 1
  defp encode_sign_type(:git_modified), do: 2
  defp encode_sign_type(:git_deleted), do: 3
  defp encode_sign_type(:diag_error), do: 4
  defp encode_sign_type(:diag_warning), do: 5
  defp encode_sign_type(:diag_info), do: 6
  defp encode_sign_type(:diag_hint), do: 7
  defp encode_sign_type(:annotation), do: 8

  # ── Gutter separator ──

  @doc """
  Encodes a gui_gutter_separator command.

  Sends the gutter column position and separator color to the GUI frontend.
  `col` is the cell column at the right edge of the gutter (0 = no separator).
  `color_rgb` is a 24-bit RGB color value.
  """
  @spec encode_gui_gutter_separator(non_neg_integer(), non_neg_integer()) :: binary()
  def encode_gui_gutter_separator(col, color_rgb)
      when is_integer(col) and is_integer(color_rgb) do
    r = color_rgb >>> 16 &&& 0xFF
    g = color_rgb >>> 8 &&& 0xFF
    b = color_rgb &&& 0xFF
    <<@op_gui_gutter_separator, col::16, r::8, g::8, b::8>>
  end

  # ── Bottom panel ──

  @doc """
  Encodes a gui_bottom_panel command from a `BottomPanel.t()`.

  Wire format:
    When visible:
      opcode(1) + visible=1(1) + active_tab_index(1) + height_percent(1)
      + filter_preset(1) + tab_count(1) + tab_defs... + content_payload
    Per tab_def:
      tab_type(1) + name_len(1) + name(name_len)
    Messages content_payload (when active tab is :messages):
      entry_count(2) + entries...
    Per entry:
      id(4) + level(1) + subsystem(1) + timestamp_secs(4)
      + path_len(2) + path(path_len) + text_len(2) + text(text_len)
    When hidden:
      opcode(1) + visible=0(1)
  """
  @spec encode_gui_bottom_panel(
          Minga.Editor.BottomPanel.t(),
          Minga.UI.Panel.MessageStore.t()
        ) :: {binary(), Minga.UI.Panel.MessageStore.t()}
  def encode_gui_bottom_panel(%{visible: false}, store) do
    {<<@op_gui_bottom_panel, 0>>, store}
  end

  def encode_gui_bottom_panel(%{visible: true} = panel, store) do
    alias Minga.Editor.BottomPanel
    alias Minga.UI.Panel.MessageStore

    active_index =
      Enum.find_index(panel.tabs, &(&1 == panel.active_tab)) || 0

    tab_defs =
      for tab <- panel.tabs, into: <<>> do
        name = BottomPanel.tab_name(tab)
        name_bytes = byte_size(name)
        <<BottomPanel.tab_type_byte(tab)::8, name_bytes::8, name::binary>>
      end

    header =
      <<@op_gui_bottom_panel, 1, active_index::8, panel.height_percent::8,
        BottomPanel.filter_byte(panel.filter)::8, length(panel.tabs)::8, tab_defs::binary>>

    # Append content payload for the active tab
    case panel.active_tab do
      :messages ->
        new_entries = MessageStore.entries_since(store, store.last_sent_id)
        content = encode_message_entries(new_entries)
        last_id = if new_entries == [], do: store.last_sent_id, else: List.last(new_entries).id
        {header <> content, MessageStore.mark_sent(store, last_id)}

      _ ->
        # No content for other tabs yet
        {header <> <<0::16>>, store}
    end
  end

  @spec encode_message_entries([Minga.UI.Panel.MessageStore.Entry.t()]) :: binary()
  defp encode_message_entries(entries) do
    alias Minga.UI.Panel.MessageStore

    count = length(entries)

    entry_data =
      for entry <- entries, into: <<>> do
        path_bytes = entry.file_path || ""
        path_len = byte_size(path_bytes)
        text_bytes = entry.text
        text_len = byte_size(text_bytes)
        # Seconds since midnight for compact timestamp
        ts_secs =
          NaiveDateTime.to_time(entry.timestamp) |> Time.to_seconds_after_midnight() |> elem(0)

        <<entry.id::32, MessageStore.level_byte(entry.level)::8,
          MessageStore.subsystem_byte(entry.subsystem)::8, ts_secs::32, path_len::16,
          path_bytes::binary, text_len::16, text_bytes::binary>>
      end

    <<count::16, entry_data::binary>>
  end

  # ── Theme ──

  @doc """
  Encodes a gui_theme command from a `Theme.t()`.

  Takes a `Theme.t()` and produces a binary with `{slot_id:u8, r:u8, g:u8, b:u8}`
  entries for every color slot the GUI needs. Colors that are nil are skipped.
  """
  @spec encode_gui_theme(Minga.UI.Theme.t()) :: binary()
  def encode_gui_theme(%Minga.UI.Theme{} = theme) do
    pairs =
      theme
      |> Slots.to_color_pairs()
      |> Enum.reject(fn {_slot, color} -> is_nil(color) end)

    count = length(pairs)

    entries =
      Enum.map(pairs, fn {slot, rgb} ->
        r = bsr(band(rgb, 0xFF0000), 16)
        g = bsr(band(rgb, 0x00FF00), 8)
        b = band(rgb, 0x0000FF)
        <<slot::8, r::8, g::8, b::8>>
      end)

    IO.iodata_to_binary([@op_gui_theme, <<count::8>> | entries])
  end

  # ── Tab bar ──

  @doc """
  Encodes a gui_tab_bar command with the current tab bar state.

  Each tab entry includes: flags byte (is_active, is_dirty, is_agent,
  has_attention, agent_status in upper bits), tab id, group_id for
  workspace grouping, Nerd Font icon, and display label.
  """
  @spec encode_gui_tab_bar(TabBar.t(), pid() | nil) :: binary()
  def encode_gui_tab_bar(%TabBar{} = tb, active_win_buffer \\ nil) do
    active_index = TabBar.active_index(tb)

    entries =
      Enum.map(tb.tabs, fn tab ->
        encode_gui_tab_entry(tab, tb.active_id, active_win_buffer)
      end)

    IO.iodata_to_binary([
      @op_gui_tab_bar,
      <<active_index::8, length(tb.tabs)::8>>
      | entries
    ])
  end

  @spec encode_gui_tab_entry(Tab.t(), pos_integer(), pid() | nil) :: binary()
  defp encode_gui_tab_entry(tab, active_id, active_win_buffer) do
    is_active = if tab.id == active_id, do: 1, else: 0
    flags = build_tab_flags(tab, is_active, active_win_buffer)
    group_id = Map.get(tab, :group_id, 0)

    icon = tab_icon(tab)
    icon_bytes = :erlang.iolist_to_binary([icon])
    label_bytes = :erlang.iolist_to_binary([tab.label])

    <<flags::8, tab.id::32, group_id::16, byte_size(icon_bytes)::8, icon_bytes::binary,
      byte_size(label_bytes)::16, label_bytes::binary>>
  end

  @spec build_tab_flags(Tab.t(), 0 | 1, pid() | nil) :: non_neg_integer()
  defp build_tab_flags(tab, is_active, active_win_buffer) do
    is_dirty = tab_dirty_bit(tab, is_active, active_win_buffer)
    is_agent = if tab.kind == :agent, do: 1, else: 0
    has_attention = if tab.attention, do: 1, else: 0
    agent_status = encode_agent_status(tab.agent_status)

    bor(
      bor(is_active, bsl(is_dirty, 1)),
      bor(
        bor(bsl(is_agent, 2), bsl(has_attention, 3)),
        bsl(agent_status, 4)
      )
    )
  end

  @spec tab_dirty_bit(Tab.t(), 0 | 1, pid() | nil) :: 0 | 1
  defp tab_dirty_bit(%{kind: :agent}, _is_active, _buf), do: 0

  defp tab_dirty_bit(tab, is_active, active_win_buffer) do
    pid = resolve_tab_buffer(tab, is_active, active_win_buffer)
    if pid && BufferServer.dirty?(pid), do: 1, else: 0
  end

  @spec resolve_tab_buffer(Tab.t(), 0 | 1, pid() | nil) :: pid() | nil
  defp resolve_tab_buffer(%{context: %{buffers: %{active: pid}}}, _is_active, _buf)
       when is_pid(pid),
       do: pid

  defp resolve_tab_buffer(_tab, 1, buf) when is_pid(buf), do: buf
  defp resolve_tab_buffer(_tab, _is_active, _buf), do: nil

  @spec encode_agent_status(atom() | nil) :: non_neg_integer()
  defp encode_agent_status(:idle), do: 0
  defp encode_agent_status(:thinking), do: 1
  defp encode_agent_status(:tool_executing), do: 2
  defp encode_agent_status(:error), do: 3
  defp encode_agent_status(_), do: 0

  @spec tab_icon(Tab.t()) :: String.t()
  defp tab_icon(%{kind: :agent}), do: Devicon.icon(:agent)
  defp tab_icon(%{kind: :file, label: label}), do: Devicon.icon(Filetype.detect(label))

  # ── Workspace bar ──

  @doc """
  Encodes a gui_agent_groups command with the current workspace state.

  Wire format:
    opcode(1) + active_group_id(2) + workspace_count(1) + workspaces...

  Per workspace:
    id(2) + kind(1) + agent_status(1) + color_r(1) + color_g(1) + color_b(1)
    + tab_count(2) + label_len(1) + label(label_len) + icon_len(1) + icon(icon_len)

  Kind: 0 = manual, 1 = agent.
  Agent status: 0 = idle, 1 = thinking, 2 = tool_executing, 3 = error.
  """
  @spec encode_gui_agent_groups(TabBar.t()) :: binary()
  def encode_gui_agent_groups(%TabBar{} = tb) do
    entries =
      Enum.map(tb.agent_groups, fn group ->
        status_byte = encode_agent_status(group.agent_status)
        r = Bitwise.bsr(Bitwise.band(group.color, 0xFF0000), 16)
        g = Bitwise.bsr(Bitwise.band(group.color, 0x00FF00), 8)
        b = Bitwise.band(group.color, 0x0000FF)
        tab_count = length(TabBar.tabs_in_group(tb, group.id))
        label_bytes = :erlang.iolist_to_binary([group.label])
        icon_bytes = :erlang.iolist_to_binary([group.icon || "cpu"])

        <<group.id::16, status_byte::8, r::8, g::8, b::8, tab_count::16,
          byte_size(label_bytes)::8, label_bytes::binary, byte_size(icon_bytes)::8,
          icon_bytes::binary>>
      end)

    IO.iodata_to_binary([
      @op_gui_agent_groups,
      <<TabBar.active_group_id(tb)::16, length(tb.agent_groups)::8>>
      | entries
    ])
  end

  # ── Board ──

  @doc """
  Encodes a gui_board command with the card grid state.

  Wire format:
    opcode(0x87) + visible(1) + focused_card_id(4) + card_count(2) + cards...

  Per card:
    card_id(4) + status(1) + flags(1)
    + task_len(2) + task(task_len)
    + model_len(1) + model(model_len)
    + elapsed_seconds(4)
    + recent_file_count(1) + recent_files...

  Per recent_file:
    path_len(2) + path(path_len)

  Status bytes: 0=idle, 1=working, 2=iterating, 3=needs_you, 4=done, 5=errored
  Flags: bit 0 = is_you_card, bit 1 = is_focused
  """
  @spec encode_gui_board(Minga.Shell.Board.State.t()) :: binary()
  def encode_gui_board(%Minga.Shell.Board.State{} = board) do
    cards = Minga.Shell.Board.State.sorted_cards(board)
    visible = if Minga.Shell.Board.State.grid_view?(board), do: 1, else: 0
    focused_id = board.focused_card || 0

    card_entries =
      Enum.map(cards, fn card ->
        encode_board_card(card, board.focused_card)
      end)

    filter_mode = if board.filter_mode, do: 1, else: 0
    filter_bytes = :erlang.iolist_to_binary([board.filter_text || ""])

    IO.iodata_to_binary([
      @op_gui_board,
      <<visible::8, focused_id::32, length(cards)::16,
        filter_mode::8, byte_size(filter_bytes)::16, filter_bytes::binary>>
      | card_entries
    ])
  end

  @spec encode_board_card(Minga.Shell.Board.Card.t(), pos_integer() | nil) :: binary()
  defp encode_board_card(card, focused_id) do
    status_byte = board_status_byte(card.status)

    is_you = if Minga.Shell.Board.Card.you_card?(card), do: 1, else: 0
    is_focused = if card.id == focused_id, do: 1, else: 0
    flags = Bitwise.bor(is_you, Bitwise.bsl(is_focused, 1))

    task_bytes = :erlang.iolist_to_binary([card.task || ""])
    model_bytes = :erlang.iolist_to_binary([card.model || ""])

    elapsed =
      if card.created_at do
        DateTime.diff(DateTime.utc_now(), card.created_at, :second)
      else
        0
      end

    recent_files = card.recent_files || []

    file_entries =
      Enum.map(recent_files, fn path ->
        path_bytes = :erlang.iolist_to_binary([path])
        <<byte_size(path_bytes)::16, path_bytes::binary>>
      end)

    IO.iodata_to_binary([
      <<card.id::32, status_byte::8, flags::8,
        byte_size(task_bytes)::16, task_bytes::binary,
        byte_size(model_bytes)::8, model_bytes::binary,
        elapsed::32,
        length(recent_files)::8>>
      | file_entries
    ])
  end

  @spec board_status_byte(Minga.Shell.Board.Card.status()) :: non_neg_integer()
  defp board_status_byte(:idle), do: 0
  defp board_status_byte(:working), do: 1
  defp board_status_byte(:iterating), do: 2
  defp board_status_byte(:needs_you), do: 3
  defp board_status_byte(:done), do: 4
  defp board_status_byte(:errored), do: 5
  defp board_status_byte(_), do: 0

  # ── Clipboard write (forward-compatible, 0x90+) ──

  @typedoc "Clipboard target for the write opcode."
  @type clipboard_target :: :general | :find

  @doc """
  Encodes a clipboard_write command.

  Uses the forward-compatible 0x90+ format: opcode(1) + payload_length(2) + payload.
  Payload: target(1) + text_length(2) + text(text_length).

  Target: 0 = general pasteboard (Cmd+C), 1 = find pasteboard (Cmd+E).
  """
  @spec encode_clipboard_write(String.t(), clipboard_target()) :: binary()
  def encode_clipboard_write(text, target \\ :general) do
    target_byte = if target == :find, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    text_len = byte_size(text_bytes)
    payload_len = 1 + 2 + text_len

    <<@op_clipboard_write, payload_len::16, target_byte::8, text_len::16, text_bytes::binary>>
  end

  # ── File tree ──

  @doc """
  Encodes a gui_file_tree command with the visible file tree entries.

  Sends: selected_index, tree_width, entry_count, root_len, root, then per entry:
  path_hash, flags (is_dir, is_expanded), depth, git_status, icon, name, rel_path.
  """
  @spec encode_gui_file_tree(Minga.Project.FileTree.t() | nil) :: binary()
  def encode_gui_file_tree(nil), do: <<@op_gui_file_tree, 0::16, 0::16, 0::16, 0::16>>

  def encode_gui_file_tree(%Minga.Project.FileTree{} = tree) do
    entries = Minga.Project.FileTree.visible_entries(tree)
    count = length(entries)
    root_bytes = :erlang.iolist_to_binary([tree.root])

    entry_binaries =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        encode_file_tree_entry(entry, tree, index == tree.cursor)
      end)

    IO.iodata_to_binary([
      @op_gui_file_tree,
      <<tree.cursor::16, tree.width::16, count::16, byte_size(root_bytes)::16,
        root_bytes::binary>>
      | entry_binaries
    ])
  end

  @spec encode_file_tree_entry(
          Minga.Project.FileTree.entry(),
          Minga.Project.FileTree.t(),
          boolean()
        ) :: binary()
  defp encode_file_tree_entry(entry, tree, is_selected?) do
    is_dir = if entry[:dir?], do: 1, else: 0
    is_expanded = if entry[:dir?] && MapSet.member?(tree.expanded, entry.path), do: 1, else: 0
    selected_bit = if is_selected?, do: 1, else: 0

    flags =
      bor(
        is_dir,
        bor(bsl(is_expanded, 1), bsl(selected_bit, 2))
      )

    git_status = encode_git_status(Map.get(tree.git_status, entry.path))

    icon = file_tree_icon(entry)
    icon_bytes = :erlang.iolist_to_binary([icon])
    name_bytes = :erlang.iolist_to_binary([entry.name])
    rel_path = Path.relative_to(entry.path, tree.root)
    rel_path_bytes = :erlang.iolist_to_binary([rel_path])

    # Stable 32-bit hash of the file path so the GUI can use it as a
    # persistent SwiftUI identity across tree updates.
    path_hash = :erlang.phash2(entry.path, 0xFFFFFFFF)

    <<path_hash::32, flags::8, entry.depth::8, git_status::8, byte_size(icon_bytes)::8,
      icon_bytes::binary, byte_size(name_bytes)::16, name_bytes::binary,
      byte_size(rel_path_bytes)::16, rel_path_bytes::binary>>
  end

  # Nerd Font folder icon (nf-md-folder)
  @folder_icon "\u{F024B}"

  @spec file_tree_icon(Minga.Project.FileTree.entry()) :: String.t()
  defp file_tree_icon(%{dir?: true}), do: @folder_icon
  defp file_tree_icon(%{name: name}), do: Devicon.icon(Filetype.detect(name))

  @spec encode_git_status(atom() | nil) :: non_neg_integer()
  defp encode_git_status(nil), do: 0
  defp encode_git_status(:modified), do: 1
  defp encode_git_status(:staged), do: 2
  defp encode_git_status(:untracked), do: 3
  defp encode_git_status(:conflict), do: 4
  defp encode_git_status(:ignored), do: 5
  defp encode_git_status(_), do: 0

  # ── Completion ──

  @doc "Encodes a gui_completion command."
  @spec encode_gui_completion(
          Minga.Editing.Completion.t() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) ::
          binary()
  def encode_gui_completion(nil, _row, _col), do: <<@op_gui_completion, 0::8>>

  def encode_gui_completion(%Minga.Editing.Completion{filtered: []}, _row, _col) do
    <<@op_gui_completion, 0::8>>
  end

  def encode_gui_completion(%Minga.Editing.Completion{} = comp, cursor_row, cursor_col) do
    items = Enum.take(comp.filtered, comp.max_visible)

    entries =
      Enum.map(items, fn item ->
        kind_byte = encode_completion_kind(item.kind)
        label = :erlang.iolist_to_binary([item.label])
        detail = :erlang.iolist_to_binary([item.detail || ""])

        <<kind_byte::8, byte_size(label)::16, label::binary, byte_size(detail)::16,
          detail::binary>>
      end)

    IO.iodata_to_binary([
      @op_gui_completion,
      <<1::8, cursor_row::16, cursor_col::16, comp.selected::16, length(items)::16>>
      | entries
    ])
  end

  @spec encode_completion_kind(atom()) :: non_neg_integer()
  defp encode_completion_kind(:function), do: 1
  defp encode_completion_kind(:method), do: 2
  defp encode_completion_kind(:variable), do: 3
  defp encode_completion_kind(:field), do: 4
  defp encode_completion_kind(:module), do: 5
  defp encode_completion_kind(:keyword), do: 7
  defp encode_completion_kind(:snippet), do: 8
  defp encode_completion_kind(:constant), do: 9
  defp encode_completion_kind(:struct), do: 11
  defp encode_completion_kind(:enum), do: 12
  defp encode_completion_kind(_), do: 0

  # ── Which-key ──

  @doc "Encodes a gui_which_key command."
  @spec encode_gui_which_key(Minga.Editor.State.WhichKey.t()) :: binary()
  def encode_gui_which_key(%{show: false}), do: <<@op_gui_which_key, 0::8>>
  def encode_gui_which_key(%{show: true, node: nil}), do: <<@op_gui_which_key, 0::8>>

  def encode_gui_which_key(%{show: true, node: node, prefix_keys: prefix_keys, page: page}) do
    bindings = Minga.UI.WhichKey.bindings_from_node(node)
    prefix_bytes = prefix_keys |> Enum.join(" ") |> :erlang.iolist_to_binary()

    page_size = 20
    page_count = max(div(length(bindings) + page_size - 1, page_size), 1)
    page_bindings = bindings |> Enum.drop(page * page_size) |> Enum.take(page_size)

    entries =
      Enum.map(page_bindings, fn b ->
        kind_byte = if b.kind == :group, do: 1, else: 0
        key = :erlang.iolist_to_binary([b.key])
        desc = :erlang.iolist_to_binary([b.description])
        icon = :erlang.iolist_to_binary([b.icon || ""])

        <<kind_byte::8, byte_size(key)::8, key::binary, byte_size(desc)::16, desc::binary,
          byte_size(icon)::8, icon::binary>>
      end)

    IO.iodata_to_binary([
      @op_gui_which_key,
      <<1::8, byte_size(prefix_bytes)::16, prefix_bytes::binary, page::8, page_count::8,
        length(page_bindings)::16>>
      | entries
    ])
  end

  # ── Breadcrumb ──

  @doc "Encodes a gui_breadcrumb command."
  @spec encode_gui_breadcrumb(String.t() | nil, String.t()) :: binary()
  def encode_gui_breadcrumb(nil, _root), do: <<@op_gui_breadcrumb, 0::8>>

  def encode_gui_breadcrumb(file_path, root) do
    segments = file_path |> Path.relative_to(root) |> Path.split()

    entries =
      Enum.map(segments, fn seg ->
        seg_bytes = :erlang.iolist_to_binary([seg])
        <<byte_size(seg_bytes)::16, seg_bytes::binary>>
      end)

    IO.iodata_to_binary([@op_gui_breadcrumb, <<length(segments)::8>> | entries])
  end

  # ── Status bar ──

  @doc """
  Encodes a gui_status_bar command from a `StatusBar.Data.t()` tagged union.

  Wire format (opcode 0x76):

  Buffer variant (content_kind == 0):
    [opcode:1][content_kind=0:1][mode:1][cursor_line:4][cursor_col:4][line_count:4]
    [flags:1][lsp_status:1][git_branch_len:1][git_branch:N]
    [message_len:2][message:N][filetype_len:1][filetype:N]
    [error_count:2][warning_count:2]
    -- Extended fields (parity with TUI modeline) --
    [info_count:2][hint_count:2]
    [macro_recording:1]
    [parser_status:1][agent_status:1]
    [git_added:2][git_modified:2][git_deleted:2]
    [icon_len:1][icon:N][icon_color_r:1][icon_color_g:1][icon_color_b:1]
    [filename_len:2][filename:N]

  Agent variant (content_kind == 1):
    [opcode:1][content_kind=1:1][mode:1]
    [zeros:4][zeros:4][zeros:4]        <- shared header slots, zero for agent
    [zeros:1][zeros:1][zeros:1][zeros:2][zeros:1][zeros:2][zeros:2]
    [model_name_len:1][model_name:N]
    [message_count:4][session_status:1]

  `content_kind`: 0 = buffer window, 1 = agent chat window.
  `cursor_line`/`cursor_col` are 1-indexed on the wire (0-indexed in BEAM state).
  """
  @spec encode_gui_status_bar(Minga.Editor.StatusBar.Data.t()) :: binary()
  def encode_gui_status_bar({:buffer, d}) do
    mode_byte = encode_vim_mode(d.mode)
    lsp_byte = encode_lsp_status(d.lsp_status)
    flags = build_status_flags(d)

    git_branch = :erlang.iolist_to_binary([d.git_branch || ""])
    filetype = :erlang.iolist_to_binary([Atom.to_string(d.filetype || :text)])

    {error_count, warning_count, info_count, hint_count} =
      full_diagnostic_counts(d)

    # Extended fields for TUI modeline parity
    macro_byte = encode_macro_recording(d.macro_recording)
    parser_byte = encode_parser_status(d.parser_status)
    agent_byte = encode_agent_session_status(d.agent_status)
    {git_added, git_modified, git_deleted} = git_diff_counts(d)
    {icon, icon_color} = Minga.UI.Devicon.icon_and_color(d.filetype)
    icon_bytes = :erlang.iolist_to_binary([icon])
    icon_r = icon_color >>> 16 &&& 0xFF
    icon_g = icon_color >>> 8 &&& 0xFF
    icon_b = icon_color &&& 0xFF
    filename = :erlang.iolist_to_binary([d.file_name || ""])

    # Diagnostic hint for the cursor line (shown in status bar center when idle)
    diag_hint = :erlang.iolist_to_binary([d.diagnostic_hint || ""])

    # Status message (shown in status bar center, takes priority over diagnostic hint)
    message = :erlang.iolist_to_binary([d.status_msg || ""])

    # cursor_line/cursor_col are 0-indexed from BufferServer; encode as 1-indexed for the GUI
    <<@op_gui_status_bar, 0::8, mode_byte::8, d.cursor_line + 1::32, d.cursor_col + 1::32,
      d.line_count::32, flags::8, lsp_byte::8, byte_size(git_branch)::8, git_branch::binary,
      byte_size(message)::16, message::binary, byte_size(filetype)::8, filetype::binary,
      error_count::16, warning_count::16, info_count::16, hint_count::16, macro_byte::8,
      parser_byte::8, agent_byte::8, git_added::16, git_modified::16, git_deleted::16,
      byte_size(icon_bytes)::8, icon_bytes::binary, icon_r::8, icon_g::8, icon_b::8,
      byte_size(filename)::16, filename::binary, byte_size(diag_hint)::16, diag_hint::binary>>
  end

  def encode_gui_status_bar({:agent, d}) do
    # Same wire format as the buffer variant (background buffer context fills
    # all the standard slots), plus agent-specific fields appended at the end.
    mode_byte = encode_vim_mode(d.mode)
    lsp_byte = encode_lsp_status(d.lsp_status)
    flags = build_status_flags(d)

    git_branch = :erlang.iolist_to_binary([d.git_branch || ""])
    filetype = :erlang.iolist_to_binary([Atom.to_string(d.filetype || :text)])

    {error_count, warning_count, info_count, hint_count} =
      full_diagnostic_counts(d)

    macro_byte = encode_macro_recording(d.macro_recording)
    parser_byte = encode_parser_status(d.parser_status)
    agent_byte = encode_agent_session_status(d.agent_status)
    {git_added, git_modified, git_deleted} = git_diff_counts(d)
    {icon, icon_color} = Minga.UI.Devicon.icon_and_color(d.filetype)
    icon_bytes = :erlang.iolist_to_binary([icon])
    icon_r = icon_color >>> 16 &&& 0xFF
    icon_g = icon_color >>> 8 &&& 0xFF
    icon_b = icon_color &&& 0xFF
    filename = :erlang.iolist_to_binary([d.file_name || ""])

    diag_hint = :erlang.iolist_to_binary([d.diagnostic_hint || ""])
    message = :erlang.iolist_to_binary([d.status_msg || ""])

    # Agent-specific trailing fields
    model_name = :erlang.iolist_to_binary([d.model_name || "Agent"])
    session_status_byte = encode_agent_session_status(d.session_status)

    # content_kind=1 signals agent mode; cursor_line/col are 0-indexed, +1 for GUI
    <<@op_gui_status_bar, 1::8, mode_byte::8, d.cursor_line + 1::32, d.cursor_col + 1::32,
      d.line_count::32, flags::8, lsp_byte::8, byte_size(git_branch)::8, git_branch::binary,
      byte_size(message)::16, message::binary, byte_size(filetype)::8, filetype::binary,
      error_count::16, warning_count::16, info_count::16, hint_count::16, macro_byte::8,
      parser_byte::8, agent_byte::8, git_added::16, git_modified::16, git_deleted::16,
      byte_size(icon_bytes)::8, icon_bytes::binary, icon_r::8, icon_g::8, icon_b::8,
      byte_size(filename)::16, filename::binary, byte_size(diag_hint)::16, diag_hint::binary,
      byte_size(model_name)::8, model_name::binary, d.message_count::32, session_status_byte::8>>
  end

  @spec encode_vim_mode(atom()) :: non_neg_integer()
  defp encode_vim_mode(:normal), do: 0
  defp encode_vim_mode(:insert), do: 1
  defp encode_vim_mode(:visual), do: 2
  defp encode_vim_mode(:command), do: 3
  defp encode_vim_mode(:operator_pending), do: 4
  defp encode_vim_mode(:search), do: 5
  defp encode_vim_mode(:search_prompt), do: 5
  defp encode_vim_mode(:replace), do: 6
  defp encode_vim_mode(_), do: 0

  @spec encode_lsp_status(atom() | nil) :: non_neg_integer()
  defp encode_lsp_status(:ready), do: 1
  defp encode_lsp_status(:initializing), do: 2
  defp encode_lsp_status(:starting), do: 3
  defp encode_lsp_status(:error), do: 4
  defp encode_lsp_status(_), do: 0

  @spec full_diagnostic_counts(map()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp full_diagnostic_counts(d) do
    case d.diagnostic_counts do
      {errors, warnings, info, hints} -> {errors, warnings, info, hints}
      _ -> {0, 0, 0, 0}
    end
  end

  @spec encode_macro_recording({true, String.t()} | false) :: non_neg_integer()
  defp encode_macro_recording({true, <<char::utf8, _::binary>>})
       when char >= ?a and char <= ?z,
       do: char - ?a + 1

  defp encode_macro_recording(_), do: 0

  @spec encode_parser_status(atom() | nil) :: non_neg_integer()
  defp encode_parser_status(:available), do: 0
  defp encode_parser_status(:unavailable), do: 1
  defp encode_parser_status(:restarting), do: 2
  defp encode_parser_status(_), do: 0

  @spec git_diff_counts(map()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp git_diff_counts(%{git_diff_summary: {added, modified, deleted}}),
    do: {added, modified, deleted}

  defp git_diff_counts(_), do: {0, 0, 0}

  @spec build_status_flags(map()) :: non_neg_integer()
  defp build_status_flags(d) do
    has_lsp = if d.lsp_status && d.lsp_status != :none, do: 1, else: 0
    has_git = if d.git_branch && d.git_branch != "", do: 1, else: 0
    is_dirty = if d.dirty, do: 1, else: 0
    bor(has_lsp, bor(bsl(has_git, 1), bsl(is_dirty, 2)))
  end

  @spec encode_agent_session_status(atom() | nil) :: non_neg_integer()
  defp encode_agent_session_status(:idle), do: 0
  defp encode_agent_session_status(:thinking), do: 1
  defp encode_agent_session_status(:tool_executing), do: 2
  defp encode_agent_session_status(:error), do: 3
  defp encode_agent_session_status(_), do: 0

  # ── Picker ──

  @doc """
  Encodes a gui_picker command.

  Wire format (v2, extended):
  ```
  opcode(1) + visible(1) + selected_index(2) + filtered_count(2) + total_count(2)
  + title_len(2) + title + query_len(2) + query + has_preview(1) + item_count(2) + items...

  Per item:
    icon_color(3) + flags(1) + label_len(2) + label + desc_len(2) + desc
    + annotation_len(2) + annotation + match_pos_count(1) + match_positions(each 2 bytes)

  Flags bits:
    bit 0: two_line (file-style two-line layout)
    bit 1: marked (multi-select checkmark)
  ```
  """
  @typedoc "Action menu state: `{actions, selected_index}` or nil."
  @type action_menu_state ::
          {[{String.t(), atom()}], non_neg_integer()} | nil

  @spec encode_gui_picker(
          Minga.UI.Picker.t() | nil,
          boolean(),
          action_menu_state(),
          non_neg_integer()
        ) ::
          binary()
  def encode_gui_picker(picker, has_preview \\ false, action_menu \\ nil, max_items \\ 0)
  def encode_gui_picker(nil, _has_preview, _action_menu, _max_items), do: <<@op_gui_picker, 0::8>>

  def encode_gui_picker(%Minga.UI.Picker{} = picker, has_preview, action_menu, max_items) do
    limit = if max_items > 0, do: max_items, else: picker.max_visible
    items = Enum.take(picker.filtered, limit)
    title_bytes = :erlang.iolist_to_binary([picker.title])
    query_bytes = :erlang.iolist_to_binary([picker.query])
    filtered_count = length(picker.filtered)
    total_count = length(picker.items)
    has_preview_byte = if has_preview, do: 1, else: 0

    entries =
      Enum.map(items, fn item ->
        label_bytes = :erlang.iolist_to_binary([item.label])
        desc_bytes = :erlang.iolist_to_binary([item.description || ""])
        annotation_bytes = :erlang.iolist_to_binary([item.annotation || ""])
        icon_color = item.icon_color || 0

        flags = encode_picker_item_flags(item, picker)

        # Match positions: list of uint16 character indices
        positions = item.match_positions
        pos_count = min(length(positions), 255)

        pos_bytes =
          Enum.take(positions, pos_count) |> Enum.map(&<<&1::16>>) |> IO.iodata_to_binary()

        <<icon_color::24, flags::8, byte_size(label_bytes)::16, label_bytes::binary,
          byte_size(desc_bytes)::16, desc_bytes::binary, byte_size(annotation_bytes)::16,
          annotation_bytes::binary, pos_count::8, pos_bytes::binary>>
      end)

    action_menu_bytes = encode_picker_action_menu(action_menu)

    IO.iodata_to_binary([
      @op_gui_picker,
      <<1::8, picker.selected::16, filtered_count::16, total_count::16,
        byte_size(title_bytes)::16, title_bytes::binary, byte_size(query_bytes)::16,
        query_bytes::binary, has_preview_byte::8, length(items)::16>>,
      entries,
      action_menu_bytes
    ])
  end

  @spec encode_picker_action_menu(action_menu_state()) :: binary()
  defp encode_picker_action_menu(nil), do: <<0::8>>

  defp encode_picker_action_menu({actions, selected}) do
    action_bins =
      Enum.map(actions, fn {name, _id} ->
        name_bytes = :erlang.iolist_to_binary([name])
        <<byte_size(name_bytes)::16, name_bytes::binary>>
      end)

    IO.iodata_to_binary([
      <<1::8, selected::8, length(actions)::8>>,
      action_bins
    ])
  end

  @spec encode_picker_item_flags(Minga.UI.Picker.Item.t(), Minga.UI.Picker.t()) ::
          non_neg_integer()
  defp encode_picker_item_flags(item, picker) do
    two_line = if item.two_line, do: 1, else: 0
    marked = if Minga.UI.Picker.marked?(picker, item), do: 1, else: 0
    bor(two_line, marked <<< 1)
  end

  # ── Picker preview ──

  @typedoc "A styled text segment for preview content: {text, fg_color, bold?}."
  @type preview_segment :: {String.t(), non_neg_integer(), boolean()}

  @doc """
  Encodes a gui_picker_preview command.

  Wire format:
  ```
  opcode(1) + visible(1)

  When visible:
    opcode(1) + 1(1) + line_count(2) + lines...

  Per line:
    segment_count(1) + segments...

  Per segment:
    fg_color(3) + flags(1) + text_len(2) + text

  Flags bits:
    bit 0: bold
  ```
  """
  @spec encode_gui_picker_preview([[preview_segment()]] | nil) :: binary()
  def encode_gui_picker_preview(nil), do: <<@op_gui_picker_preview, 0::8>>

  def encode_gui_picker_preview(lines) when is_list(lines) do
    line_binaries = Enum.map(lines, &encode_preview_line/1)

    IO.iodata_to_binary([
      @op_gui_picker_preview,
      <<1::8, length(lines)::16>>
      | line_binaries
    ])
  end

  @spec encode_preview_line([preview_segment()]) :: iodata()
  defp encode_preview_line(segments) do
    seg_bins = Enum.map(segments, &encode_preview_segment/1)
    [<<length(segments)::8>> | seg_bins]
  end

  @spec encode_preview_segment(preview_segment()) :: binary()
  defp encode_preview_segment({text, fg_color, bold}) do
    text_bytes = :erlang.iolist_to_binary([text])
    flags = if bold, do: 1, else: 0
    <<fg_color::24, flags::8, byte_size(text_bytes)::16, text_bytes::binary>>
  end

  # ── Agent chat ──

  @doc """
  Encodes a gui_agent_chat command with conversation messages.

  Messages are `{id, message}` tuples where `id` is a stable BEAM-assigned
  uint32. Each encoded message is prefixed with its ID so the GUI frontend
  can use it as a persistent SwiftUI identity across updates.
  """
  @spec encode_gui_agent_chat(map()) :: binary()
  def encode_gui_agent_chat(%{visible: false}) do
    <<@op_gui_agent_chat, 0::8>>
  end

  def encode_gui_agent_chat(
        %{
          visible: true,
          messages: messages,
          status: status,
          model: model,
          prompt: prompt
        } = data
      ) do
    status_byte = encode_agent_chat_status(status)
    model_bytes = :erlang.iolist_to_binary([model || ""])
    prompt_bytes = :erlang.iolist_to_binary([prompt || ""])

    pending_bytes = encode_pending_approval(data[:pending_approval])
    help_bytes = encode_help_overlay(data[:help_visible], data[:help_groups])

    msg_binaries =
      messages
      |> Enum.take(100)
      |> Enum.map(&encode_chat_message/1)

    IO.iodata_to_binary([
      @op_gui_agent_chat,
      <<1::8, status_byte::8, byte_size(model_bytes)::16, model_bytes::binary,
        byte_size(prompt_bytes)::16, prompt_bytes::binary>>,
      pending_bytes,
      help_bytes,
      <<length(msg_binaries)::16>>
      | msg_binaries
    ])
  end

  @spec encode_pending_approval(map() | nil) :: binary()
  defp encode_pending_approval(nil), do: <<0::8>>

  defp encode_pending_approval(%{name: name, args: args}) do
    name_b = :erlang.iolist_to_binary([name])
    summary = summarize_tool_args(name, args)
    summary_b = :erlang.iolist_to_binary([summary])
    <<1::8, byte_size(name_b)::16, name_b::binary, byte_size(summary_b)::16, summary_b::binary>>
  end

  # Encodes help overlay data: help_visible flag + optional help groups.
  # Wire format: visible(1) [group_count(1) [title_len(2) title(utf8)
  #   binding_count(1) [key_len(1) key(utf8) desc_len(2) desc(utf8)]...]*]
  @spec encode_help_overlay(boolean() | nil, [{String.t(), [{String.t(), String.t()}]}] | nil) ::
          binary()
  defp encode_help_overlay(true, groups) when is_list(groups) and groups != [] do
    group_binaries =
      Enum.map(groups, fn {title, bindings} ->
        title_b = :erlang.iolist_to_binary([title])

        binding_binaries =
          Enum.map(bindings, fn {key, desc} ->
            key_b = :erlang.iolist_to_binary([key])
            desc_b = :erlang.iolist_to_binary([desc])

            <<byte_size(key_b)::8, key_b::binary, byte_size(desc_b)::16, desc_b::binary>>
          end)

        IO.iodata_to_binary([
          <<byte_size(title_b)::16, title_b::binary, length(bindings)::8>>
          | binding_binaries
        ])
      end)

    IO.iodata_to_binary([<<1::8, length(groups)::8>> | group_binaries])
  end

  defp encode_help_overlay(_, _), do: <<0::8>>

  # Computes a short summary for a tool call from its name and args.
  # Reuses summarize_tool_args/2 (shared with the approval banner).
  # Truncates to 100 chars max to keep the wire payload small.
  @spec tool_call_summary(Minga.Agent.ToolCall.t()) :: String.t()
  defp tool_call_summary(%Minga.Agent.ToolCall{name: name, args: args}) when is_map(args) do
    summarize_tool_args(name, args) |> String.slice(0, 100)
  end

  defp tool_call_summary(%Minga.Agent.ToolCall{name: name} = tc) do
    args = Map.get(tc, :args) || %{}
    summarize_tool_args(name, args) |> String.slice(0, 100)
  end

  @spec summarize_tool_args(String.t(), map()) :: String.t()
  defp summarize_tool_args("shell", %{"command" => cmd}), do: cmd
  defp summarize_tool_args("shell", %{command: cmd}), do: cmd
  defp summarize_tool_args("write_file", %{"path" => path}), do: path
  defp summarize_tool_args("write_file", %{path: path}), do: path
  defp summarize_tool_args("edit_file", %{"path" => path}), do: path
  defp summarize_tool_args("edit_file", %{path: path}), do: path
  defp summarize_tool_args("multi_edit_file", %{"path" => path}), do: path
  defp summarize_tool_args("multi_edit_file", %{path: path}), do: path

  defp summarize_tool_args("git_stage", %{"paths" => paths}) when is_list(paths),
    do: Enum.join(paths, ", ")

  defp summarize_tool_args("git_stage", %{paths: paths}) when is_list(paths),
    do: Enum.join(paths, ", ")

  defp summarize_tool_args("git_commit", %{"message" => msg}), do: msg
  defp summarize_tool_args("git_commit", %{message: msg}), do: msg
  defp summarize_tool_args(_name, args) when map_size(args) == 0, do: ""
  defp summarize_tool_args(_name, args), do: inspect(args, limit: 80)

  @typedoc "A styled text run for GUI rendering: {text, fg_rgb, bg_rgb, flags}."
  @type styled_run :: {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "A line of styled runs."
  @type styled_line :: [styled_run()]

  @typedoc "A chat message that may carry pre-computed styled runs."
  @type gui_chat_message ::
          Minga.Agent.Message.t()
          | {:styled_assistant, [[styled_run()]]}
          | {:styled_tool_call,
             %{
               name: String.t(),
               status: :running | :complete | :error,
               is_error: boolean(),
               collapsed: boolean(),
               duration_ms: non_neg_integer() | nil,
               result: String.t() | nil
             }, [[styled_run()]]}

  # Unwrap {id, message} tuple: prefix with the stable uint32 ID, then encode the message.
  @spec encode_chat_message({pos_integer(), gui_chat_message()} | gui_chat_message()) :: binary()
  defp encode_chat_message({id, msg}) when is_integer(id) do
    <<id::32, encode_chat_message_body(msg)::binary>>
  end

  # Bare messages (no ID wrapper) for backward compat in tests. ID defaults to 0.
  defp encode_chat_message(msg) when is_tuple(msg) do
    <<0::32, encode_chat_message_body(msg)::binary>>
  end

  @spec encode_chat_message_body(gui_chat_message()) :: binary()
  defp encode_chat_message_body({:user, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message_body({:user, text, _attachments}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message_body({:assistant, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x02::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  # Styled assistant message: opcode 0x07, line_count::16, then per line:
  # run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8
  defp encode_chat_message_body({:styled_assistant, styled_lines}) do
    line_binaries =
      Enum.map(styled_lines, fn runs ->
        run_binaries =
          Enum.map(runs, fn {text, fg, bg, flags} ->
            text_bytes = :erlang.iolist_to_binary([text])

            <<byte_size(text_bytes)::16, text_bytes::binary, fg::24, bg::24, flags::8>>
          end)

        [<<length(runs)::16>> | run_binaries]
      end)

    IO.iodata_to_binary([<<0x07::8, length(styled_lines)::16>> | line_binaries])
  end

  defp encode_chat_message_body({:thinking, text, collapsed}) do
    collapsed_byte = if collapsed, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x03::8, collapsed_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message_body({:tool_call, tc}) do
    name_bytes = :erlang.iolist_to_binary([tc.name])
    summary_bytes = :erlang.iolist_to_binary([tool_call_summary(tc)])
    result_bytes = :erlang.iolist_to_binary([tc.result])

    status_byte =
      case tc.status do
        :running -> 0
        :complete -> 1
        :error -> 2
      end

    duration = tc.duration_ms || 0
    error_byte = if tc.is_error, do: 1, else: 0
    collapsed_byte = if tc.collapsed, do: 1, else: 0

    <<0x04::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32,
      byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
      summary_bytes::binary, byte_size(result_bytes)::32, result_bytes::binary>>
  end

  # Styled tool call: same header fields as tool_call (0x04), but result is styled runs.
  # Sub-opcode 0x08. Layout:
  #   0x08, status::8, error::8, collapsed::8, duration::32,
  #   name_len::16, name, line_count::16, then per line:
  #   run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8
  defp encode_chat_message_body({:styled_tool_call, tc, styled_lines}) do
    name_bytes = :erlang.iolist_to_binary([tc.name])
    summary_bytes = :erlang.iolist_to_binary([tool_call_summary(tc)])

    status_byte =
      case tc.status do
        :running -> 0
        :complete -> 1
        :error -> 2
      end

    duration = tc.duration_ms || 0
    error_byte = if tc.is_error, do: 1, else: 0
    collapsed_byte = if tc.collapsed, do: 1, else: 0

    line_binaries =
      Enum.map(styled_lines, fn runs ->
        run_binaries =
          Enum.map(runs, fn {text, fg, bg, flags} ->
            text_bytes = :erlang.iolist_to_binary([text])
            <<byte_size(text_bytes)::16, text_bytes::binary, fg::24, bg::24, flags::8>>
          end)

        [<<length(runs)::16>> | run_binaries]
      end)

    IO.iodata_to_binary([
      <<0x08::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32,
        byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
        summary_bytes::binary, length(styled_lines)::16>>
      | line_binaries
    ])
  end

  defp encode_chat_message_body({:system, text, level}) do
    level_byte = if level == :error, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x05::8, level_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message_body({:usage, u}) do
    cost_int = round((u.cost || 0.0) * 1_000_000)
    <<0x06::8, u.input::32, u.output::32, u.cache_read::32, u.cache_write::32, cost_int::32>>
  end

  @spec encode_agent_chat_status(atom()) :: non_neg_integer()
  defp encode_agent_chat_status(:idle), do: 0
  defp encode_agent_chat_status(:thinking), do: 1
  defp encode_agent_chat_status(:tool_executing), do: 2
  defp encode_agent_chat_status(:error), do: 3
  defp encode_agent_chat_status(_), do: 0

  # ═══════════════════════════════════════════════════════════════════════════
  # Decoding (Frontend → BEAM)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Decodes a GUI action sub-opcode and its payload into a `gui_action()` tuple.

  Called from `Protocol.decode_event/1` when the outer opcode is `0x07` (gui_action).
  """
  @spec decode_gui_action(non_neg_integer(), binary()) :: {:ok, gui_action()} | :error
  def decode_gui_action(@gui_action_select_tab, <<id::32>>), do: {:ok, {:select_tab, id}}
  def decode_gui_action(@gui_action_close_tab, <<id::32>>), do: {:ok, {:close_tab, id}}

  def decode_gui_action(@gui_action_file_tree_click, <<index::16>>),
    do: {:ok, {:file_tree_click, index}}

  def decode_gui_action(@gui_action_file_tree_toggle, <<index::16>>),
    do: {:ok, {:file_tree_toggle, index}}

  def decode_gui_action(@gui_action_completion_select, <<index::16>>),
    do: {:ok, {:completion_select, index}}

  def decode_gui_action(@gui_action_breadcrumb_click, <<index::8>>),
    do: {:ok, {:breadcrumb_click, index}}

  def decode_gui_action(@gui_action_toggle_panel, <<panel::8>>),
    do: {:ok, {:toggle_panel, panel}}

  def decode_gui_action(@gui_action_new_tab, <<>>), do: {:ok, :new_tab}

  def decode_gui_action(@gui_action_panel_switch_tab, <<tab_index::8>>),
    do: {:ok, {:panel_switch_tab, tab_index}}

  def decode_gui_action(@gui_action_panel_dismiss, <<>>), do: {:ok, :panel_dismiss}

  def decode_gui_action(@gui_action_panel_resize, <<height_percent::8>>),
    do: {:ok, {:panel_resize, height_percent}}

  def decode_gui_action(@gui_action_open_file, <<path_len::16, path::binary-size(path_len)>>),
    do: {:ok, {:open_file, path}}

  def decode_gui_action(@gui_action_file_tree_new_file, <<>>), do: {:ok, :file_tree_new_file}

  def decode_gui_action(@gui_action_file_tree_new_folder, <<>>),
    do: {:ok, :file_tree_new_folder}

  def decode_gui_action(@gui_action_file_tree_collapse_all, <<>>),
    do: {:ok, :file_tree_collapse_all}

  def decode_gui_action(@gui_action_file_tree_refresh, <<>>), do: {:ok, :file_tree_refresh}

  def decode_gui_action(@gui_action_tool_install, <<name_len::16, name::binary-size(name_len)>>),
    do: {:ok, {:tool_install, name}}

  def decode_gui_action(
        @gui_action_tool_uninstall,
        <<name_len::16, name::binary-size(name_len)>>
      ),
      do: {:ok, {:tool_uninstall, name}}

  def decode_gui_action(@gui_action_tool_update, <<name_len::16, name::binary-size(name_len)>>),
    do: {:ok, {:tool_update, name}}

  def decode_gui_action(@gui_action_tool_dismiss, <<>>), do: {:ok, :tool_dismiss}

  def decode_gui_action(@gui_action_agent_tool_toggle, <<index::16>>),
    do: {:ok, {:agent_tool_toggle, index}}

  def decode_gui_action(
        @gui_action_execute_command,
        <<name_len::16, name::binary-size(name_len)>>
      ),
      do: {:ok, {:execute_command, name}}

  def decode_gui_action(@gui_action_minibuffer_select, <<index::16>>),
    do: {:ok, {:minibuffer_select, index}}

  def decode_gui_action(
        @gui_action_git_stage_file,
        <<path_len::16, path::binary-size(path_len)>>
      ),
      do: {:ok, {:git_stage_file, path}}

  def decode_gui_action(
        @gui_action_git_unstage_file,
        <<path_len::16, path::binary-size(path_len)>>
      ),
      do: {:ok, {:git_unstage_file, path}}

  def decode_gui_action(
        @gui_action_git_discard_file,
        <<path_len::16, path::binary-size(path_len)>>
      ),
      do: {:ok, {:git_discard_file, path}}

  def decode_gui_action(@gui_action_git_stage_all, <<>>),
    do: {:ok, :git_stage_all}

  def decode_gui_action(@gui_action_git_unstage_all, <<>>),
    do: {:ok, :git_unstage_all}

  def decode_gui_action(@gui_action_git_commit, <<msg_len::16, message::binary-size(msg_len)>>),
    do: {:ok, {:git_commit, message}}

  def decode_gui_action(@gui_action_git_open_file, <<path_len::16, path::binary-size(path_len)>>),
    do: {:ok, {:git_open_file, path}}

  def decode_gui_action(
        @gui_action_agent_group_rename,
        <<ws_id::16, name_len::16, name::binary-size(name_len)>>
      ),
      do: {:ok, {:agent_group_rename, ws_id, name}}

  def decode_gui_action(
        @gui_action_agent_group_set_icon,
        <<ws_id::16, icon_len::8, icon::binary-size(icon_len)>>
      ),
      do: {:ok, {:agent_group_set_icon, ws_id, icon}}

  def decode_gui_action(@gui_action_agent_group_close, <<ws_id::16>>),
    do: {:ok, {:agent_group_close, ws_id}}

  def decode_gui_action(
        @gui_action_space_leader_chord,
        <<codepoint::32, modifiers::8>>
      ),
      do: {:ok, {:space_leader_chord, codepoint, modifiers}}

  def decode_gui_action(
        @gui_action_space_leader_retract,
        <<codepoint::32, modifiers::8>>
      ),
      do: {:ok, {:space_leader_retract, codepoint, modifiers}}

  def decode_gui_action(
        @gui_action_find_pasteboard_search,
        <<direction::8, text_len::16, text::binary-size(text_len)>>
      ),
      do: {:ok, {:find_pasteboard_search, text, direction}}

  def decode_gui_action(@gui_action_board_select_card, <<card_id::32>>),
    do: {:ok, {:board_select_card, card_id}}

  def decode_gui_action(@gui_action_board_close_card, <<card_id::32>>),
    do: {:ok, {:board_close_card, card_id}}

  def decode_gui_action(_, _), do: :error

  # ═══════════════════════════════════════════════════════════════════════════
  # Tool Manager (BEAM → Frontend)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Encodes the tool manager panel state.

  Sends a rich structured view of all available tools with their install
  status, versions, categories, and progress info. The GUI frontend
  renders this as a native management panel.

  ## Wire format

      When visible:
        opcode(1) + 1(1) + filter(1) + selected_index(2) + tool_count(2) + tools...

      Per tool:
        name_len(1) + name(name_len) + label_len(1) + label(label_len)
        + desc_len(2) + desc(desc_len) + category(1) + status(1)
        + method(1) + language_count(1) + languages...
        + version_len(1) + version(version_len)
        + homepage_len(2) + homepage(homepage_len)
        + provides_count(1) + provides...
        + error_reason_len(2) + error_reason(error_reason_len)

      Per language:
        lang_len(1) + lang(lang_len)

      Per provides:
        cmd_len(1) + cmd(cmd_len)

      When hidden:
        opcode(1) + 0(1)

  ## Status values

  | Value | Status          |
  |-------|-----------------|
  | 0     | not_installed   |
  | 1     | installed       |
  | 2     | installing      |
  | 3     | update_available|
  | 4     | failed          |

  ## Category values

  | Value | Category    |
  |-------|-------------|
  | 0     | lsp_server  |
  | 1     | formatter   |
  | 2     | linter      |
  | 3     | debugger    |

  ## Method values

  | Value | Method          |
  |-------|-----------------|
  | 0     | npm             |
  | 1     | pip             |
  | 2     | cargo           |
  | 3     | go_install      |
  | 4     | github_release  |

  ## Filter values

  | Value | Filter        |
  |-------|---------------|
  | 0     | all           |
  | 1     | installed     |
  | 2     | not_installed |
  | 3     | lsp_servers   |
  | 4     | formatters    |
  """
  @spec encode_gui_tool_manager(map() | nil) :: binary()
  def encode_gui_tool_manager(nil), do: <<@op_gui_tool_manager, 0::8>>

  def encode_gui_tool_manager(%{visible: false}), do: <<@op_gui_tool_manager, 0::8>>

  def encode_gui_tool_manager(%{
        visible: true,
        filter: filter,
        selected_index: selected,
        tools: tools
      }) do
    filter_byte = encode_tool_filter(filter)
    tool_count = length(tools)

    tool_data =
      Enum.map(tools, fn tool ->
        name_str = Atom.to_string(tool.name)
        name_len = byte_size(name_str)
        label_len = byte_size(tool.label)
        desc_len = byte_size(tool.description)
        category = encode_tool_category(tool.category)
        status = encode_tool_status(tool.status)
        method = encode_tool_method(tool.method)
        version = tool.version || ""
        version_len = byte_size(version)
        homepage = tool.homepage || ""
        homepage_len = byte_size(homepage)
        error_reason = tool.error_reason || ""
        error_reason_len = byte_size(error_reason)

        lang_data =
          Enum.map(tool.languages, fn lang ->
            lang_str = Atom.to_string(lang)
            <<byte_size(lang_str)::8, lang_str::binary>>
          end)

        provides_data =
          Enum.map(tool.provides, fn cmd ->
            <<byte_size(cmd)::8, cmd::binary>>
          end)

        <<name_len::8, name_str::binary, label_len::8, tool.label::binary, desc_len::16,
          tool.description::binary, category::8, status::8, method::8, length(tool.languages)::8>> <>
          IO.iodata_to_binary(lang_data) <>
          <<version_len::8, version::binary, homepage_len::16, homepage::binary,
            length(tool.provides)::8>> <>
          IO.iodata_to_binary(provides_data) <>
          <<error_reason_len::16, error_reason::binary>>
      end)

    <<@op_gui_tool_manager, 1::8, filter_byte::8, selected::16, tool_count::16>> <>
      IO.iodata_to_binary(tool_data)
  end

  @spec encode_tool_filter(atom()) :: non_neg_integer()
  defp encode_tool_filter(:all), do: 0
  defp encode_tool_filter(:installed), do: 1
  defp encode_tool_filter(:not_installed), do: 2
  defp encode_tool_filter(:lsp_servers), do: 3
  defp encode_tool_filter(:formatters), do: 4
  defp encode_tool_filter(_), do: 0

  @spec encode_tool_category(atom()) :: non_neg_integer()
  defp encode_tool_category(:lsp_server), do: 0
  defp encode_tool_category(:formatter), do: 1
  defp encode_tool_category(:linter), do: 2
  defp encode_tool_category(:debugger), do: 3
  defp encode_tool_category(_), do: 0

  @spec encode_tool_status(atom()) :: non_neg_integer()
  defp encode_tool_status(:not_installed), do: 0
  defp encode_tool_status(:installed), do: 1
  defp encode_tool_status(:installing), do: 2
  defp encode_tool_status(:update_available), do: 3
  defp encode_tool_status(:failed), do: 4
  defp encode_tool_status(_), do: 0

  @spec encode_tool_method(atom()) :: non_neg_integer()
  defp encode_tool_method(:npm), do: 0
  defp encode_tool_method(:pip), do: 1
  defp encode_tool_method(:cargo), do: 2
  defp encode_tool_method(:go_install), do: 3
  defp encode_tool_method(:github_release), do: 4
  defp encode_tool_method(_), do: 0

  # ── Minibuffer ──

  @doc """
  Encodes a gui_minibuffer command (0x7F).

  Sends structured minibuffer state to the GUI frontend for native rendering.
  Includes mode, prompt, input text, cursor position, context string, and
  completion candidates.

  When `visible` is false, sends a single hide byte. When visible, encodes
  the full payload including any completion candidates.
  """
  @spec encode_gui_minibuffer(MinibufferData.t()) :: binary()
  def encode_gui_minibuffer(%MinibufferData{visible: false}),
    do: <<@op_gui_minibuffer, 0::8>>

  def encode_gui_minibuffer(
        %{
          visible: true,
          mode: mode,
          cursor_pos: cursor_pos,
          prompt: prompt,
          input: input,
          context: context,
          selected_index: selected_index,
          candidates: candidates
        } = data
      ) do
    total_candidates = Map.get(data, :total_candidates, length(candidates))
    prompt_bytes = :erlang.iolist_to_binary([prompt])
    input_bytes = :erlang.iolist_to_binary([input])
    context_bytes = :erlang.iolist_to_binary([context])

    candidate_data =
      Enum.map(candidates, fn candidate ->
        %{label: label, description: desc, match_score: score} = candidate
        match_positions = Map.get(candidate, :match_positions, [])
        annotation = Map.get(candidate, :annotation, "")

        label_bytes = :erlang.iolist_to_binary([label])
        desc_bytes = :erlang.iolist_to_binary([desc])
        annotation_bytes = :erlang.iolist_to_binary([annotation])

        # Per candidate: score(1) + label_len(2) + label + desc_len(2) + desc
        #   + annotation_len(2) + annotation
        #   + match_pos_count(1) + match_positions(count * 2)
        pos_binary =
          Enum.map(match_positions, fn pos -> <<min(pos, 0xFFFF)::16>> end)

        [
          <<min(score, 255)::8, byte_size(label_bytes)::16, label_bytes::binary,
            byte_size(desc_bytes)::16, desc_bytes::binary, byte_size(annotation_bytes)::16,
            annotation_bytes::binary, length(match_positions)::8>>
          | pos_binary
        ]
      end)

    IO.iodata_to_binary([
      <<@op_gui_minibuffer, 1::8, mode::8, cursor_pos::16, byte_size(prompt_bytes)::8,
        prompt_bytes::binary, byte_size(input_bytes)::16, input_bytes::binary,
        byte_size(context_bytes)::16, context_bytes::binary, selected_index::16,
        length(candidates)::16, total_candidates::16>>
      | candidate_data
    ])
  end

  # ── Hover Popup ──

  @doc """
  Encodes a gui_hover_popup command (0x81).

  Wire format:
    opcode(1) + visible(1) + anchor_row(2) + anchor_col(2) + focused(1) +
    scroll_offset(2) + line_count(2) + lines...

  Each line:
    line_type(1) + segment_count(2) + segments...

  Each segment:
    style(1) + text_len(2) + text(text_len)

  Line types: 0=text, 1=code, 2=code_header, 3=header, 4=blockquote,
    5=list_item, 6=rule, 7=empty

  Segment styles: 0=plain, 1=bold, 2=italic, 3=bold_italic,
    4=code, 5=code_block, 6=code_content, 7=header1, 8=header2, 9=header3,
    10=blockquote, 11=list_bullet, 12=rule
  """
  @spec encode_gui_hover_popup(Minga.Editor.HoverPopup.t() | nil) :: binary()
  def encode_gui_hover_popup(nil), do: <<@op_gui_hover_popup, 0::8>>

  def encode_gui_hover_popup(%Minga.Editor.HoverPopup{content_lines: []}) do
    <<@op_gui_hover_popup, 0::8>>
  end

  def encode_gui_hover_popup(%Minga.Editor.HoverPopup{} = popup) do
    focused_byte = if popup.focused, do: 1, else: 0

    line_data =
      Enum.map(popup.content_lines, fn {segments, line_type} ->
        line_type_byte = encode_line_type(line_type)

        segment_data =
          Enum.map(segments, fn {text, style} ->
            style_byte = encode_markdown_style(style)
            text_bytes = :erlang.iolist_to_binary([text])
            <<style_byte::8, byte_size(text_bytes)::16, text_bytes::binary>>
          end)

        [<<line_type_byte::8, length(segments)::16>> | segment_data]
      end)

    IO.iodata_to_binary([
      <<@op_gui_hover_popup, 1::8, popup.anchor_row::16, popup.anchor_col::16, focused_byte::8,
        popup.scroll_offset::16, length(popup.content_lines)::16>>
      | line_data
    ])
  end

  # ── Signature Help ──

  @doc """
  Encodes a gui_signature_help command (0x82).

  Wire format:
    opcode(1) + visible(1) + anchor_row(2) + anchor_col(2) +
    active_signature(1) + active_parameter(1) + signature_count(1) +
    signatures...

  Each signature:
    label_len(2) + label + doc_len(2) + doc + param_count(1) + params...

  Each parameter:
    label_len(2) + label + doc_len(2) + doc
  """
  @spec encode_gui_signature_help(Minga.Editor.SignatureHelp.t() | nil) :: binary()
  def encode_gui_signature_help(nil), do: <<@op_gui_signature_help, 0::8>>

  def encode_gui_signature_help(%Minga.Editor.SignatureHelp{signatures: []}) do
    <<@op_gui_signature_help, 0::8>>
  end

  def encode_gui_signature_help(%Minga.Editor.SignatureHelp{} = sh) do
    sig_data =
      Enum.map(sh.signatures, fn sig ->
        label_bytes = :erlang.iolist_to_binary([sig.label])
        doc_bytes = :erlang.iolist_to_binary([sig.documentation])

        param_data =
          Enum.map(sig.parameters, fn param ->
            p_label = :erlang.iolist_to_binary([param.label])
            p_doc = :erlang.iolist_to_binary([param.documentation])
            <<byte_size(p_label)::16, p_label::binary, byte_size(p_doc)::16, p_doc::binary>>
          end)

        [
          <<byte_size(label_bytes)::16, label_bytes::binary, byte_size(doc_bytes)::16,
            doc_bytes::binary, length(sig.parameters)::8>>
          | param_data
        ]
      end)

    IO.iodata_to_binary([
      <<@op_gui_signature_help, 1::8, sh.anchor_row::16, sh.anchor_col::16,
        sh.active_signature::8, sh.active_parameter::8, length(sh.signatures)::8>>
      | sig_data
    ])
  end

  # ── Float Popup ──

  @typedoc "Data for a float popup."
  @type float_popup_data :: %{
          visible: boolean(),
          title: String.t(),
          lines: [String.t()],
          width: non_neg_integer(),
          height: non_neg_integer()
        }

  @doc """
  Encodes a gui_float_popup command (0x83).

  Wire format:
    opcode(1) + visible(1) + width(2) + height(2) +
    title_len(2) + title(title_len) + line_count(2) + lines...

  Each line:
    text_len(2) + text(text_len)

  When visible=0, no further fields are sent.
  """
  @spec encode_gui_float_popup(float_popup_data()) :: binary()
  def encode_gui_float_popup(%{visible: false}) do
    <<@op_gui_float_popup, 0::8>>
  end

  def encode_gui_float_popup(%{visible: true, title: title, lines: lines, width: w, height: h}) do
    title_bytes = IO.iodata_to_binary(title)

    line_data =
      Enum.map(lines, fn line ->
        text = IO.iodata_to_binary(line)
        <<byte_size(text)::16, text::binary>>
      end)

    IO.iodata_to_binary([
      <<@op_gui_float_popup, 1::8, w::16, h::16, byte_size(title_bytes)::16, title_bytes::binary,
        length(lines)::16>>
      | line_data
    ])
  end

  # ── Split Separators ──

  @typedoc "A vertical split separator."
  @type vertical_separator ::
          {col :: non_neg_integer(), start_row :: non_neg_integer(), end_row :: non_neg_integer()}

  @typedoc "A horizontal split separator with filename."
  @type horizontal_separator ::
          {row :: non_neg_integer(), col :: non_neg_integer(), width :: non_neg_integer(),
           filename :: String.t()}

  @doc """
  Encodes a gui_split_separators command (0x84).

  Wire format:
    opcode(1) + border_color_rgb(3) +
    vertical_count(1) + verticals... +
    horizontal_count(1) + horizontals...

  Each vertical: col(2) + start_row(2) + end_row(2)
  Each horizontal: row(2) + col(2) + width(2) + filename_len(2) + filename
  """
  @spec encode_gui_split_separators(
          non_neg_integer(),
          [vertical_separator()],
          [horizontal_separator()]
        ) :: binary()
  def encode_gui_split_separators(border_color_rgb, verticals, horizontals) do
    r = border_color_rgb >>> 16 &&& 0xFF
    g = border_color_rgb >>> 8 &&& 0xFF
    b = border_color_rgb &&& 0xFF

    vert_data =
      Enum.map(verticals, fn {col, start_row, end_row} ->
        <<col::16, start_row::16, end_row::16>>
      end)

    horiz_data =
      Enum.map(horizontals, fn {row, col, width, filename} ->
        name_bytes = IO.iodata_to_binary(filename)
        <<row::16, col::16, width::16, byte_size(name_bytes)::16, name_bytes::binary>>
      end)

    IO.iodata_to_binary([
      <<@op_gui_split_separators, r::8, g::8, b::8, length(verticals)::8>>,
      vert_data,
      <<length(horizontals)::8>>,
      horiz_data
    ])
  end

  # ── Git status panel (0x85) ──

  @typedoc "Git status panel data for encoding."
  @type git_status_data :: %{
          repo_state: :normal | :not_a_repo | :loading,
          branch: String.t(),
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          entries: [Minga.Git.StatusEntry.t()]
        }

  @doc """
  Encodes a gui_git_status command (0x85) for the native GUI frontend.

  Wire format:
    opcode:1, repo_state:1, ahead:2, behind:2, branch_len:2, branch,
    entry_count:2, then per entry:
      path_hash:4, section:1, status:1, path_len:2, path
  """
  @spec encode_gui_git_status(git_status_data()) :: binary()
  def encode_gui_git_status(%{
        repo_state: repo_state,
        branch: branch,
        ahead: ahead,
        behind: behind,
        entries: entries
      }) do
    repo_state_byte = encode_repo_state(repo_state)
    branch_bytes = :erlang.iolist_to_binary([branch || ""])
    entry_count = length(entries)

    entry_binaries =
      Enum.map(entries, fn entry ->
        path_bytes = :erlang.iolist_to_binary([entry.path])
        path_hash = :erlang.phash2(entry.path, 0xFFFFFFFF)
        section = encode_status_section(entry)
        status = encode_file_status(entry.status)

        <<path_hash::32, section::8, status::8, byte_size(path_bytes)::16, path_bytes::binary>>
      end)

    IO.iodata_to_binary([
      <<@op_gui_git_status, repo_state_byte::8, ahead::16, behind::16,
        byte_size(branch_bytes)::16, branch_bytes::binary, entry_count::16>>
      | entry_binaries
    ])
  end

  @spec encode_repo_state(:normal | :not_a_repo | :loading) :: non_neg_integer()
  defp encode_repo_state(:normal), do: 0
  defp encode_repo_state(:not_a_repo), do: 1
  defp encode_repo_state(:loading), do: 2

  @spec encode_status_section(Minga.Git.StatusEntry.t()) :: non_neg_integer()
  defp encode_status_section(%{staged: true}), do: 0
  defp encode_status_section(%{status: :untracked}), do: 2
  defp encode_status_section(%{status: :conflict}), do: 3
  defp encode_status_section(_), do: 1

  @spec encode_file_status(atom()) :: non_neg_integer()
  defp encode_file_status(:modified), do: 1
  defp encode_file_status(:added), do: 2
  defp encode_file_status(:deleted), do: 3
  defp encode_file_status(:renamed), do: 4
  defp encode_file_status(:copied), do: 5
  defp encode_file_status(:untracked), do: 6
  defp encode_file_status(:conflict), do: 7
  defp encode_file_status(:unknown), do: 0

  # ── Shared encoding helpers for hover/overlay content ──

  @spec encode_markdown_style(Minga.Agent.Markdown.style()) :: non_neg_integer()
  defp encode_markdown_style(:plain), do: 0
  defp encode_markdown_style(:bold), do: 1
  defp encode_markdown_style(:italic), do: 2
  defp encode_markdown_style(:bold_italic), do: 3
  defp encode_markdown_style(:code), do: 4
  defp encode_markdown_style(:code_block), do: 5
  defp encode_markdown_style({:code_content, _lang}), do: 6
  defp encode_markdown_style(:header1), do: 7
  defp encode_markdown_style(:header2), do: 8
  defp encode_markdown_style(:header3), do: 9
  defp encode_markdown_style(:blockquote), do: 10
  defp encode_markdown_style(:list_bullet), do: 11
  defp encode_markdown_style(:rule), do: 12
  defp encode_markdown_style(_), do: 0

  @spec encode_line_type(Minga.Agent.Markdown.line_type()) :: non_neg_integer()
  defp encode_line_type(:text), do: 0
  defp encode_line_type(:code), do: 1
  defp encode_line_type({:code_header, _lang}), do: 2
  defp encode_line_type(:header), do: 3
  defp encode_line_type(:blockquote), do: 4
  defp encode_line_type(:list_item), do: 5
  defp encode_line_type(:rule), do: 6
  defp encode_line_type(:empty), do: 7
  defp encode_line_type(_), do: 0
end
