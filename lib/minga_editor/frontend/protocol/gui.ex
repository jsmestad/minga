defmodule MingaEditor.Frontend.Protocol.GUI do
  @moduledoc """
  Binary protocol encoder/decoder for GUI chrome commands (BEAM → Swift/GTK).

  This module handles the structured data protocol for native GUI elements:
  tab bars, file trees, which-key popups, completion menus, breadcrumbs,
  status bars, pickers, agent chat, and theme colors. These are separate
  from the TUI cell-grid rendering commands in `MingaEditor.Frontend.Protocol`.

  ## GUI Chrome Commands (BEAM → Frontend)

  GUI chrome opcodes start at 0x70. Newer commands use the 0x90+ length-prefixed envelope so frontends can skip unknown messages.

  | Opcode | Name            | Description                    |
  |--------|-----------------|--------------------------------|
  | 0x93   | gui_file_tree   | Semantic file tree state       |
  | 0x94   | gui_file_tree_selection | File tree selection-only update |
  | 0x71   | gui_tab_bar     | Tab bar with tab entries       |
  | 0x72   | gui_which_key   | Which-key popup bindings       |
  | 0x73   | gui_completion  | Completion popup items         |
  | 0x74   | gui_theme       | Theme color slots              |
  | 0x75   | gui_breadcrumb  | Path breadcrumb segments       |
  | 0x76   | gui_status_bar  | Status bar data                |
  | 0x77   | gui_picker      | Fuzzy picker items + mode prefix |
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
  | 0x98   | gui_workspaces    | Canonical workspace state |
  | 0x87   | gui_board           | Board card grid state      |
  | 0x97   | gui_config_state    | Settings panel state       |

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
  | 0x2D       | file_tree_edit_confirm |
  | 0x2E       | file_tree_edit_cancel  |
  | 0x2F       | scroll_to_line         |
  | 0x30       | file_tree_delete       |
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
  | 0x1F       | workspace_rename     |
  | 0x20       | workspace_set_icon   |
  | 0x21       | workspace_close      |
  | 0x3D       | file_tree_open_in_split |
  | 0x3E       | tab_copy_path           |
  | 0x3F       | hover_open_action       |
  | 0x40       | file_tree_drop          |
  | 0x41       | fold_toggle_at_line     |
  | 0x42       | git_open_diff           |
  | 0x43       | config_update           |
  | 0x44       | config_query            |
  | 0x47       | power_thermal_state     |
  | 0x48       | tab_reorder             |
  | 0x34       | system_will_sleep       |
  | 0x35       | system_did_wake         |

  """

  import Bitwise

  alias Minga.Buffer
  alias Minga.Config.Options
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings
  alias MingaEditor.FileTree.Diagnostics, as: FileTreeDiagnostics
  alias MingaEditor.FileTree.DropIntent
  alias MingaEditor.FileTree.Row
  alias MingaEditor.MinibufferData
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias Minga.Language
  alias MingaEditor.UI.Devicon
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter
  alias MingaEditor.UI.Theme.Slots
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary
  alias MingaEditor.Session.ChromeState.WorkspaceSummary

  alias Minga.Protocol.Opcodes

  @op_gui_tab_bar Opcodes.gui_tab_bar()
  @op_gui_which_key Opcodes.gui_which_key()
  @op_gui_completion Opcodes.gui_completion()
  @op_gui_theme Opcodes.gui_theme()
  @op_gui_breadcrumb Opcodes.gui_breadcrumb()
  @op_gui_status_bar Opcodes.gui_status_bar()
  @op_gui_picker Opcodes.gui_picker()
  @op_gui_agent_chat Opcodes.gui_agent_chat()
  @op_gui_gutter_sep Opcodes.gui_gutter_sep()
  @op_gui_cursorline Opcodes.gui_cursorline()
  @op_gui_gutter Opcodes.gui_gutter()
  @op_gui_bottom_panel Opcodes.gui_bottom_panel()
  @op_gui_picker_preview Opcodes.gui_picker_preview()
  @op_gui_tool_manager Opcodes.gui_tool_manager()
  @op_gui_minibuffer Opcodes.gui_minibuffer()
  @op_clipboard_write Opcodes.clipboard_write()
  @op_gui_indent_guides Opcodes.gui_indent_guides()
  @op_gui_line_spacing Opcodes.gui_line_spacing()
  @op_gui_file_tree Opcodes.gui_file_tree()
  @op_gui_file_tree_selection Opcodes.gui_file_tree_selection()
  @op_gui_cursor_animation Opcodes.gui_cursor_animation()
  @op_gui_hover_popup Opcodes.gui_hover_popup()
  @op_gui_signature_help Opcodes.gui_signature_help()
  @op_gui_float_popup Opcodes.gui_float_popup()
  @op_gui_split_separators Opcodes.gui_split_separators()
  @op_gui_git_status Opcodes.gui_git_status()
  @op_gui_workspaces Opcodes.gui_workspaces()
  @op_gui_board Opcodes.gui_board()
  @op_gui_agent_context Opcodes.gui_agent_context()
  @op_gui_change_summary Opcodes.gui_change_summary()
  @op_gui_hover_action Opcodes.gui_hover_action()
  @op_gui_config_state Opcodes.gui_config_state()
  @op_gui_notifications Opcodes.gui_notifications()

  @gui_action_select_tab Opcodes.gui_action_select_tab()
  @gui_action_close_tab Opcodes.gui_action_close_tab()
  @gui_action_file_tree_click Opcodes.gui_action_file_tree_click()
  @gui_action_file_tree_toggle Opcodes.gui_action_file_tree_toggle()
  @gui_action_completion_select Opcodes.gui_action_completion_select()
  @gui_action_breadcrumb_click Opcodes.gui_action_breadcrumb_click()
  @gui_action_toggle_panel Opcodes.gui_action_toggle_panel()
  @gui_action_new_tab Opcodes.gui_action_new_tab()
  @gui_action_panel_switch_tab Opcodes.gui_action_panel_switch_tab()
  @gui_action_panel_dismiss Opcodes.gui_action_panel_dismiss()
  @gui_action_panel_resize Opcodes.gui_action_panel_resize()
  @gui_action_open_file Opcodes.gui_action_open_file()
  @gui_action_file_tree_new_file Opcodes.gui_action_file_tree_new_file()
  @gui_action_file_tree_new_folder Opcodes.gui_action_file_tree_new_folder()
  @gui_action_file_tree_collapse_all Opcodes.gui_action_file_tree_collapse_all()
  @gui_action_file_tree_refresh Opcodes.gui_action_file_tree_refresh()
  @gui_action_tool_install Opcodes.gui_action_tool_install()
  @gui_action_tool_uninstall Opcodes.gui_action_tool_uninstall()
  @gui_action_tool_update Opcodes.gui_action_tool_update()
  @gui_action_tool_dismiss Opcodes.gui_action_tool_dismiss()
  @gui_action_agent_tool_toggle Opcodes.gui_action_agent_tool_toggle()
  @gui_action_execute_command Opcodes.gui_action_execute_command()
  @gui_action_minibuffer_select Opcodes.gui_action_minibuffer_select()
  @gui_action_git_stage_file Opcodes.gui_action_git_stage_file()
  @gui_action_git_unstage_file Opcodes.gui_action_git_unstage_file()
  @gui_action_git_discard_file Opcodes.gui_action_git_discard_file()
  @gui_action_git_stage_all Opcodes.gui_action_git_stage_all()
  @gui_action_git_unstage_all Opcodes.gui_action_git_unstage_all()
  @gui_action_git_commit Opcodes.gui_action_git_commit()
  @gui_action_git_open_file Opcodes.gui_action_git_open_file()
  @gui_action_workspace_rename Opcodes.gui_action_workspace_rename()
  @gui_action_workspace_set_icon Opcodes.gui_action_workspace_set_icon()
  @gui_action_workspace_close Opcodes.gui_action_workspace_close()
  @gui_action_space_leader_chord Opcodes.gui_action_space_leader_chord()
  @gui_action_space_leader_retract Opcodes.gui_action_space_leader_retract()
  @gui_action_find_pasteboard_search Opcodes.gui_action_find_pasteboard_search()
  @gui_action_board_select_card Opcodes.gui_action_board_select_card()
  @gui_action_board_close_card Opcodes.gui_action_board_close_card()
  @gui_action_board_reorder Opcodes.gui_action_board_reorder()
  @gui_action_board_dispatch_agent Opcodes.gui_action_board_dispatch_agent()
  @gui_action_agent_approve Opcodes.gui_action_agent_approve()
  @gui_action_agent_request_changes Opcodes.gui_action_agent_request_changes()
  @gui_action_agent_dismiss Opcodes.gui_action_agent_dismiss()
  @gui_action_change_summary_click Opcodes.gui_action_change_summary_click()
  @gui_action_file_tree_edit_confirm Opcodes.gui_action_file_tree_edit_confirm()
  @gui_action_file_tree_edit_cancel Opcodes.gui_action_file_tree_edit_cancel()
  @gui_action_scroll_to_line Opcodes.gui_action_scroll_to_line()
  @gui_action_file_tree_delete Opcodes.gui_action_file_tree_delete()
  @gui_action_file_tree_rename Opcodes.gui_action_file_tree_rename()
  @gui_action_file_tree_duplicate Opcodes.gui_action_file_tree_duplicate()
  @gui_action_file_tree_move Opcodes.gui_action_file_tree_move()
  @gui_action_system_will_sleep Opcodes.gui_action_system_will_sleep()
  @gui_action_system_did_wake Opcodes.gui_action_system_did_wake()
  @gui_action_power_thermal_state Opcodes.gui_action_power_thermal_state()
  @gui_action_cmd_copy Opcodes.gui_action_cmd_copy()
  @gui_action_cmd_cut Opcodes.gui_action_cmd_cut()
  @gui_action_git_push Opcodes.gui_action_git_push()
  @gui_action_git_pull Opcodes.gui_action_git_pull()
  @gui_action_git_fetch Opcodes.gui_action_git_fetch()
  @gui_action_git_commit_amend Opcodes.gui_action_git_commit_amend()
  @gui_action_git_pull_and_retry Opcodes.gui_action_git_pull_and_retry()
  @gui_action_file_tree_open_in_split Opcodes.gui_action_file_tree_open_in_split()
  @gui_action_tab_copy_path Opcodes.gui_action_tab_copy_path()
  @gui_action_hover_open_action Opcodes.gui_action_hover_open_action()
  @gui_action_tab_reorder Opcodes.gui_action_tab_reorder()
  @gui_action_file_tree_drop Opcodes.gui_action_file_tree_drop()
  @gui_action_fold_toggle_at_line Opcodes.gui_action_fold_toggle_at_line()
  @gui_action_git_open_diff Opcodes.gui_action_git_open_diff()
  @gui_action_config_update Opcodes.gui_action_config_update()
  @gui_action_config_query Opcodes.gui_action_config_query()
  @gui_action_notification_dismiss Opcodes.gui_action_notification_dismiss()
  @gui_action_notification_action Opcodes.gui_action_notification_action()

  @max_u8 255
  @max_u16 65_535
  @max_u32 4_294_967_295
  @max_modeline_segments 128

  @typedoc "macOS thermal pressure level reported by the native GUI frontend."
  @type thermal_state :: :nominal | :fair | :serious | :critical | {:unknown, non_neg_integer()}

  @chat_message_limit 100
  @max_chat_text_bytes 60_000
  @truncation_suffix "\n… [truncated]"
  @chat_payload_omission_notice "Some agent chat content was omitted because the GUI chat payload exceeded 65KB."

  # ── Sectioned format section IDs ──
  # Used by opcodes that encode their fields in self-describing sections.
  # Format: section_id(1) + section_len(2, big-endian) + payload(section_len)
  # Unknown sections are skipped by reading the length. See #1228.

  # gui_status_bar sections
  @section_identity 0x01
  @section_cursor 0x02
  @section_diagnostics 0x03
  @section_language 0x04
  @section_git 0x05
  @section_file 0x06
  @section_message 0x07
  @section_recording 0x08
  @section_agent 0x09
  @section_indent 0x0A
  @section_modeline_segments 0x0B
  @section_selection 0x0C
  @section_workspace 0x0D

  # gui_gutter sections
  @section_gutter_window 0x01
  @section_gutter_config 0x02
  @section_gutter_entries 0x03

  # gui_picker sections
  @section_picker_header 0x01
  @section_picker_query 0x02
  @section_picker_items 0x03
  @section_picker_action_menu 0x04
  @section_picker_mode_prefix 0x05

  # gui_agent_chat sections
  @section_chat_header 0x01
  @section_chat_model 0x02
  @section_chat_prompt 0x03
  @section_chat_pending 0x04
  @section_chat_help 0x05
  @section_chat_messages 0x06
  @section_chat_completion 0x07
  @section_chat_thinking 0x08

  @value_boolean 0x01
  @value_integer 0x02
  @value_string 0x03
  @value_atom 0x04
  @value_float 0x05

  @settings_options [
    :theme,
    :font_family,
    :font_size,
    :font_weight,
    :font_ligatures,
    :tab_width,
    :line_numbers,
    :wrap,
    :cursorline,
    :cursor_blink
  ]

  @no_fold_range 0xFFFF_FFFF

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
          | {:file_tree_new_file, index :: non_neg_integer()}
          | {:file_tree_new_folder, index :: non_neg_integer()}
          | {:file_tree_edit_confirm, text :: String.t()}
          | :file_tree_edit_cancel
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
          | {:git_commit, message :: String.t(), amend? :: boolean()}
          | {:git_open_file, path :: String.t()}
          | {:git_open_diff, path :: String.t(), section :: non_neg_integer()}
          | {:workspace_rename, id :: non_neg_integer(), name :: String.t()}
          | {:workspace_set_icon, id :: non_neg_integer(), icon :: String.t()}
          | {:workspace_close, id :: non_neg_integer()}
          | {:space_leader_chord, codepoint :: non_neg_integer(), modifiers :: non_neg_integer()}
          | {:space_leader_retract, codepoint :: non_neg_integer(),
             modifiers :: non_neg_integer()}
          | {:find_pasteboard_search, text :: String.t(), direction :: non_neg_integer()}
          | {:board_select_card, card_id :: pos_integer()}
          | {:board_close_card, card_id :: pos_integer()}
          | {:board_reorder, card_id :: pos_integer(), new_index :: non_neg_integer()}
          | {:board_dispatch_agent, task :: String.t(), model :: String.t()}
          | :agent_approve
          | :agent_request_changes
          | :agent_dismiss
          | {:change_summary_click, index :: non_neg_integer()}
          | {:file_tree_delete, index :: non_neg_integer()}
          | {:file_tree_rename, index :: non_neg_integer()}
          | {:file_tree_duplicate, index :: non_neg_integer()}
          | {:file_tree_move, source_index :: non_neg_integer(),
             target_dir_index :: non_neg_integer()}
          | {:file_tree_drop, DropIntent.t()}
          | {:fold_toggle_at_line, window_id :: non_neg_integer(),
             buffer_line :: non_neg_integer()}
          | {:file_tree_open_in_split, index :: non_neg_integer()}
          | {:tab_copy_path, id :: pos_integer()}
          | {:tab_reorder, id :: pos_integer(), new_index :: non_neg_integer()}
          | :hover_open_action
          | :system_will_sleep
          | :system_did_wake
          | {:power_thermal_state, low_power? :: boolean(), thermal_state()}
          | :cmd_copy
          | :cmd_cut
          | :git_push
          | :git_pull
          | :git_fetch
          | {:git_commit_amend, message :: String.t()}
          | :git_pull_and_retry
          | {:config_update, Options.option_name(), term()}
          | :config_query
          | {:notification_dismiss, notification_id :: String.t()}
          | {:notification_action, notification_id :: String.t(), action_id :: String.t()}

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
  @type display_type ::
          :normal | :fold_start | :fold_continuation | :wrap_continuation | :fold_open

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
          optional(:fold_end_line) => non_neg_integer(),
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
          content_width: non_neg_integer(),
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
    + is_active(1) + content_width(2) + cursor_line(4) + line_number_style(1)
    + line_number_width(1) + sign_col_width(1) + line_count(2) + entries...

  Per entry:
    buf_line(4) + display_type(1) + sign_type(1) + fold_end_line(4)

  `fold_end_line` is `0xFFFFFFFF` when the row has no fold range.
  """
  @spec encode_gui_gutter(gutter_data()) :: binary()
  def encode_gui_gutter(
        %{
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
        } = data
      ) do
    content_width = Map.get(data, :content_width, 0)
    style_byte = encode_line_number_style(style)
    active_byte = if active, do: 1, else: 0
    count = length(entries)

    entry_binaries =
      Enum.map(entries, fn entry ->
        fold_end_line = Map.get(entry, :fold_end_line, @no_fold_range)

        base =
          <<entry.buf_line::32, encode_display_type(entry.display_type)::8,
            encode_sign_type(entry.sign_type)::8, fold_end_line::32>>

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

    entries_payload = IO.iodata_to_binary([<<count::16>> | entry_binaries])

    sections = [
      encode_section(
        @section_gutter_window,
        <<window_id::16, row::16, col::16, height::16, active_byte::8, content_width::16>>
      ),
      encode_section(
        @section_gutter_config,
        <<cursor_line::32, style_byte::8, ln_width::8, sign_width::8>>
      ),
      encode_section(@section_gutter_entries, entries_payload)
    ]

    IO.iodata_to_binary([<<@op_gui_gutter, length(sections)::8>> | sections])
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
  defp encode_display_type(:fold_open), do: 4

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
    <<@op_gui_gutter_sep, col::16, r::8, g::8, b::8>>
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
          MingaEditor.BottomPanel.t(),
          MingaEditor.UI.Panel.MessageStore.t()
        ) :: {binary(), MingaEditor.UI.Panel.MessageStore.t()}
  def encode_gui_bottom_panel(%{visible: false}, store) do
    {<<@op_gui_bottom_panel, 0>>, store}
  end

  def encode_gui_bottom_panel(%{visible: true} = panel, store) do
    alias MingaEditor.BottomPanel
    alias MingaEditor.UI.Panel.MessageStore

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

  @spec encode_message_entries([MingaEditor.UI.Panel.MessageStore.Entry.t()]) :: binary()
  defp encode_message_entries(entries) do
    alias MingaEditor.UI.Panel.MessageStore

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
  @spec encode_gui_theme(MingaEditor.UI.Theme.t()) :: binary()
  def encode_gui_theme(%MingaEditor.UI.Theme{} = theme) do
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
  workspace grouping, Nerd Font icon, and display label. When the active
  tab is omitted from `ChromeState.visible_tabs`, active_index is 255 to
  signal that no visible tab is active.
  """
  @no_visible_active_tab 255

  @spec encode_gui_tab_bar(TabBar.t() | ChromeState.t(), pid() | nil) :: binary()
  def encode_gui_tab_bar(tab_bar_or_chrome_state, active_win_buffer \\ nil)

  def encode_gui_tab_bar(%ChromeState{} = chrome_state, _active_win_buffer) do
    active_index = active_summary_index(chrome_state)

    entries =
      Enum.map(chrome_state.visible_tabs, fn tab ->
        encode_gui_tab_entry(tab, chrome_state.active_tab_id)
      end)

    IO.iodata_to_binary([
      @op_gui_tab_bar,
      <<active_index::8, length(chrome_state.visible_tabs)::8>>
      | entries
    ])
  end

  def encode_gui_tab_bar(%TabBar{} = tb, active_win_buffer) do
    visible_tabs = TabBar.visible_file_tabs(tb)

    active_index =
      case Enum.find_index(visible_tabs, &(&1.id == tb.active_id)) do
        nil -> @no_visible_active_tab
        index -> index
      end

    entries =
      Enum.map(visible_tabs, fn tab ->
        encode_gui_tab_entry(tab, tb.active_id, active_win_buffer)
      end)

    IO.iodata_to_binary([
      @op_gui_tab_bar,
      <<active_index::8, length(visible_tabs)::8>>
      | entries
    ])
  end

  @spec active_summary_index(ChromeState.t()) :: non_neg_integer()
  defp active_summary_index(%ChromeState{visible_tabs: tabs, active_tab_id: active_id}) do
    case Enum.find_index(tabs, &(&1.id == active_id)) do
      nil -> @no_visible_active_tab
      index -> index
    end
  end

  @spec encode_gui_tab_entry(Tab.t(), pos_integer(), pid() | nil) :: binary()
  defp encode_gui_tab_entry(tab, active_id, active_win_buffer) do
    is_active = if tab.id == active_id, do: 1, else: 0
    flags = build_tab_flags(tab, is_active, active_win_buffer)
    group_id = Map.get(tab, :group_id, 0)

    icon = tab_icon(tab)
    icon_bytes = :erlang.iolist_to_binary([icon])
    label_bytes = :erlang.iolist_to_binary([MingaEditor.State.Tab.display_label(tab)])

    <<flags::8, tab.id::32, group_id::16, byte_size(icon_bytes)::8, icon_bytes::binary,
      byte_size(label_bytes)::16, label_bytes::binary, tab_tint_color(tab)::32>>
  end

  @spec encode_gui_tab_entry(TabSummary.t(), Tab.id() | nil) :: binary()
  defp encode_gui_tab_entry(%TabSummary{} = tab, active_id) do
    is_active = if tab.id == active_id, do: 1, else: 0
    flags = build_tab_summary_flags(tab, is_active)
    icon_bytes = :erlang.iolist_to_binary([tab.icon])
    label_bytes = :erlang.iolist_to_binary([tab.label])

    <<flags::8, tab.id::32, tab.workspace_id::16, byte_size(icon_bytes)::8, icon_bytes::binary,
      byte_size(label_bytes)::16, label_bytes::binary, tab.tint_color::32>>
  end

  @spec build_tab_flags(Tab.t(), 0 | 1, pid() | nil) :: non_neg_integer()
  defp build_tab_flags(tab, is_active, active_win_buffer) do
    is_dirty = tab_dirty_bit(tab, is_active, active_win_buffer)
    is_agent = if tab.kind == :agent, do: 1, else: 0
    has_attention = if tab.attention, do: 1, else: 0
    is_pinned = if tab.pinned?, do: 1, else: 0
    agent_status = encode_agent_status(tab.agent_status)

    tab_flags(is_active, is_dirty, is_agent, has_attention, agent_status, is_pinned)
  end

  @spec build_tab_summary_flags(TabSummary.t(), 0 | 1) :: non_neg_integer()
  defp build_tab_summary_flags(%TabSummary{} = tab, is_active) do
    is_dirty = if tab.dirty?, do: 1, else: 0
    is_agent = if tab.kind == :agent, do: 1, else: 0
    has_attention = if tab.attention?, do: 1, else: 0
    is_pinned = if tab.pinned?, do: 1, else: 0
    tab_flags(is_active, is_dirty, is_agent, has_attention, 0, is_pinned)
  end

  @spec tab_flags(0 | 1, 0 | 1, 0 | 1, 0 | 1, non_neg_integer(), 0 | 1) :: non_neg_integer()
  defp tab_flags(is_active, is_dirty, is_agent, has_attention, agent_status, is_pinned) do
    bor(
      bor(is_active, bsl(is_dirty, 1)),
      bor(
        bor(bsl(is_agent, 2), bsl(has_attention, 3)),
        bor(bsl(band(agent_status, 0x07), 4), bsl(is_pinned, 7))
      )
    )
  end

  @spec tab_tint_color(Tab.t()) :: non_neg_integer()
  defp tab_tint_color(%Tab{kind: :agent}), do: 0x7AA2F7
  defp tab_tint_color(%Tab{}), do: 0

  @spec tab_dirty_bit(Tab.t(), 0 | 1, pid() | nil) :: 0 | 1
  defp tab_dirty_bit(%{kind: :agent}, _is_active, _buf), do: 0

  defp tab_dirty_bit(tab, is_active, active_win_buffer) do
    pid = resolve_tab_buffer(tab, is_active, active_win_buffer)
    if pid && Buffer.dirty?(pid), do: 1, else: 0
  end

  @spec resolve_tab_buffer(Tab.t(), 0 | 1, pid() | nil) :: pid() | nil
  defp resolve_tab_buffer(%{context: context}, is_active, buf) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: pid}} when is_pid(pid) -> pid
      _ -> active_tab_buffer(is_active, buf)
    end
  end

  defp resolve_tab_buffer(_tab, is_active, buf), do: active_tab_buffer(is_active, buf)

  @spec active_tab_buffer(0 | 1, pid() | nil) :: pid() | nil
  defp active_tab_buffer(1, buf) when is_pid(buf), do: buf
  defp active_tab_buffer(_is_active, _buf), do: nil

  @spec encode_agent_status(atom() | nil) :: non_neg_integer()
  defp encode_agent_status(:idle), do: 0
  defp encode_agent_status(:thinking), do: 1
  defp encode_agent_status(:tool_executing), do: 2
  defp encode_agent_status(:error), do: 3
  defp encode_agent_status(:plan), do: 4
  defp encode_agent_status(_), do: 0

  @spec tab_icon(Tab.t()) :: String.t()
  defp tab_icon(%{kind: :agent}), do: Devicon.icon(:agent)
  defp tab_icon(%{kind: :file, label: label}), do: Devicon.icon(Language.detect_filetype(label))

  # ── Workspace bar ──

  @doc """
  Encodes the canonical gui_workspaces command.

  Wire format:
    opcode(1) + payload_len(2) + payload

  Payload:
    version(1) + active_workspace_id(2) + mode(1) + flags(1) + workspace_count(1)
    + workspaces... + visible_tab_count(2) + visible_tabs...
  """
  @spec encode_gui_workspaces(ChromeState.t()) :: binary()
  def encode_gui_workspaces(%ChromeState{} = chrome_state) do
    payload = encode_gui_workspaces_payload(chrome_state)
    <<@op_gui_workspaces, byte_size(payload)::16, payload::binary>>
  end

  @spec encode_gui_workspaces_payload(ChromeState.t()) :: binary()
  defp encode_gui_workspaces_payload(%ChromeState{} = chrome_state) do
    workspace_budget = @max_u16 - 6 - 2

    {workspace_entries, remaining_budget} =
      bounded_entries(
        chrome_state.workspaces,
        &encode_gui_workspace_summary/1,
        @max_u8,
        workspace_budget
      )

    {visible_tab_entries, _remaining_budget} =
      bounded_entries(
        chrome_state.visible_tabs,
        &encode_gui_visible_tab/1,
        @max_u16,
        remaining_budget
      )

    IO.iodata_to_binary([
      <<2::8, chrome_state.active_workspace_id::16, encode_workspace_mode(chrome_state.mode)::8,
        encode_workspace_flags(chrome_state)::8, length(workspace_entries)::8>>,
      workspace_entries,
      <<length(visible_tab_entries)::16>>,
      visible_tab_entries
    ])
  end

  @spec bounded_entries([term()], (term() -> binary()), non_neg_integer(), non_neg_integer()) ::
          {[binary()], non_neg_integer()}
  defp bounded_entries(items, encode_fun, max_count, budget) do
    {entries, remaining_budget, _count} =
      Enum.reduce_while(items, {[], budget, 0}, fn item, acc ->
        item |> encode_fun.() |> maybe_add_bounded_entry(acc, max_count)
      end)

    {Enum.reverse(entries), remaining_budget}
  end

  @spec maybe_add_bounded_entry(
          binary(),
          {[binary()], non_neg_integer(), non_neg_integer()},
          non_neg_integer()
        ) ::
          {:cont, {[binary()], non_neg_integer(), non_neg_integer()}}
          | {:halt, {[binary()], non_neg_integer(), non_neg_integer()}}
  defp maybe_add_bounded_entry(_entry, acc = {_entries, _budget, count}, max_count)
       when count >= max_count do
    {:halt, acc}
  end

  defp maybe_add_bounded_entry(entry, {entries, budget, count}, _max_count)
       when byte_size(entry) <= budget do
    {:cont, {[entry | entries], budget - byte_size(entry), count + 1}}
  end

  defp maybe_add_bounded_entry(_entry, acc, _max_count), do: {:halt, acc}

  @spec encode_gui_workspace_summary(WorkspaceSummary.t()) :: binary()
  defp encode_gui_workspace_summary(%WorkspaceSummary{} = workspace) do
    {r, g, b} = encode_rgb(workspace.color)
    label_bytes = utf8_prefix_bytes(workspace.label, 255)
    icon_bytes = utf8_prefix_bytes(workspace.icon, 255)

    <<workspace.id::16, encode_workspace_kind(workspace.kind)::8,
      encode_agent_status(workspace.status)::8, encode_workspace_entry_flags(workspace)::16, r::8,
      g::8, b::8, workspace.tab_count::16, workspace.draft_count::16,
      workspace.conflict_count::16, workspace.running_background_count::16,
      byte_size(label_bytes)::8, label_bytes::binary, byte_size(icon_bytes)::8,
      icon_bytes::binary>>
  end

  @spec encode_gui_visible_tab(TabSummary.t()) :: binary()
  defp encode_gui_visible_tab(%TabSummary{} = tab) do
    icon_bytes = utf8_prefix_bytes(tab.icon, 255)
    label_bytes = utf8_prefix_bytes(tab.label, @max_u16)
    path_bytes = utf8_prefix_bytes(tab.path || "", @max_u16)

    <<tab.id::32, tab.workspace_id::16, encode_tab_kind(tab.kind)::8,
      encode_visible_tab_flags(tab)::16, path_hash(tab.path)::32, byte_size(icon_bytes)::8,
      icon_bytes::binary, byte_size(label_bytes)::16, label_bytes::binary,
      byte_size(path_bytes)::16, path_bytes::binary, tab.tint_color::32>>
  end

  @spec encode_workspace_mode(ChromeState.mode()) :: non_neg_integer()
  defp encode_workspace_mode(:editor), do: 0
  defp encode_workspace_mode(:agent), do: 1
  defp encode_workspace_mode(:file_tree), do: 2
  defp encode_workspace_mode(:other), do: 3

  @spec encode_workspace_flags(ChromeState.t()) :: non_neg_integer()
  defp encode_workspace_flags(%ChromeState{} = chrome_state) do
    if chrome_state.attention_count > 0, do: 0x01, else: 0x00
  end

  @spec encode_workspace_kind(WorkspaceSummary.kind() | TabSummary.kind()) :: non_neg_integer()
  defp encode_workspace_kind(:manual), do: 0
  defp encode_workspace_kind(:agent), do: 1
  defp encode_workspace_kind(:file), do: 0

  @spec encode_workspace_entry_flags(WorkspaceSummary.t()) :: non_neg_integer()
  defp encode_workspace_entry_flags(%WorkspaceSummary{} = workspace) do
    0
    |> maybe_workspace_flag(workspace.attention?, 0x01)
    |> maybe_workspace_flag(workspace.closeable?, 0x02)
  end

  @spec encode_tab_kind(TabSummary.kind()) :: non_neg_integer()
  defp encode_tab_kind(:file), do: 0

  @spec encode_visible_tab_flags(TabSummary.t()) :: non_neg_integer()
  defp encode_visible_tab_flags(%TabSummary{} = tab) do
    0
    |> maybe_workspace_flag(tab.dirty?, 0x01)
    |> maybe_workspace_flag(tab.attention?, 0x02)
    |> maybe_workspace_flag(tab.draft_state == :draft, 0x04)
    |> maybe_workspace_flag(tab.draft_state == :draft_elsewhere, 0x08)
    |> maybe_workspace_flag(tab.draft_state == :conflict, 0x10)
    |> maybe_workspace_flag(tab.pinned?, 0x20)
  end

  @spec maybe_workspace_flag(non_neg_integer(), boolean(), non_neg_integer()) :: non_neg_integer()
  defp maybe_workspace_flag(flags, true, bit), do: flags ||| bit
  defp maybe_workspace_flag(flags, false, _bit), do: flags

  @spec encode_rgb(non_neg_integer()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp encode_rgb(color) when is_integer(color) do
    {Bitwise.bsr(Bitwise.band(color, 0xFF0000), 16),
     Bitwise.bsr(Bitwise.band(color, 0x00FF00), 8), Bitwise.band(color, 0x0000FF)}
  end

  @spec path_hash(String.t() | nil) :: non_neg_integer()
  defp path_hash(nil), do: 0
  defp path_hash(path) when is_binary(path), do: :erlang.phash2(path, @max_u32)

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
  @spec encode_gui_board(MingaEditor.Shell.Board.State.t()) :: binary()
  def encode_gui_board(%MingaEditor.Shell.Board.State{} = board) do
    cards = MingaEditor.Shell.Board.State.sorted_cards(board)
    visible = if MingaEditor.Shell.Board.State.grid_view?(board), do: 1, else: 0
    focused_id = board.focused_card || 0

    card_entries =
      Enum.map(cards, fn card ->
        encode_board_card(card, board.focused_card)
      end)

    filter_mode = if board.filter_mode, do: 1, else: 0
    filter_bytes = :erlang.iolist_to_binary([board.filter_text])

    IO.iodata_to_binary([
      @op_gui_board,
      <<visible::8, focused_id::32, length(cards)::16, filter_mode::8,
        byte_size(filter_bytes)::16, filter_bytes::binary>>
      | card_entries
    ])
  end

  @spec encode_board_card(MingaEditor.Shell.Board.Card.t(), pos_integer() | nil) :: binary()
  defp encode_board_card(card, focused_id) do
    status_byte = board_status_byte(card.status)

    is_you = if MingaEditor.Shell.Board.Card.you_card?(card), do: 1, else: 0
    is_focused = if card.id == focused_id, do: 1, else: 0
    flags = Bitwise.bor(is_you, Bitwise.bsl(is_focused, 1))

    task_bytes = :erlang.iolist_to_binary([MingaEditor.Shell.Board.Card.display_task(card)])
    model_bytes = :erlang.iolist_to_binary([card.model || ""])

    # Send Unix timestamp so Swift can compute elapsed time locally
    dispatch_timestamp = DateTime.to_unix(card.created_at)

    recent_files = card.recent_files

    file_entries =
      Enum.map(recent_files, fn path ->
        path_bytes = :erlang.iolist_to_binary([path])
        <<byte_size(path_bytes)::16, path_bytes::binary>>
      end)

    # Encode sparkline data as half-precision floats (Float16)
    sparkline = card.sparkline
    sparkline_count = length(sparkline)

    sparkline_bytes =
      sparkline
      |> Enum.map(&encode_float16/1)
      |> IO.iodata_to_binary()

    IO.iodata_to_binary([
      <<card.id::32, status_byte::8, flags::8, byte_size(task_bytes)::16, task_bytes::binary,
        byte_size(model_bytes)::8, model_bytes::binary, dispatch_timestamp::32,
        length(recent_files)::8>>,
      file_entries,
      <<sparkline_count::8, sparkline_bytes::binary>>
    ])
  end

  # Encode a float as Float16 (half-precision, 16 bits)
  # Simple approximation: clamp to [0.0, 1.0], scale to [0, 65535]
  @spec encode_float16(float()) :: binary()
  defp encode_float16(value) do
    clamped = max(0.0, min(1.0, value))
    scaled = round(clamped * 65_535.0)
    <<scaled::16>>
  end

  @spec board_status_byte(MingaEditor.Shell.Board.Card.status()) :: non_neg_integer()
  defp board_status_byte(:idle), do: 0
  defp board_status_byte(:working), do: 1
  defp board_status_byte(:iterating), do: 2
  defp board_status_byte(:needs_you), do: 3
  defp board_status_byte(:done), do: 4
  defp board_status_byte(:errored), do: 5
  defp board_status_byte(_), do: 0

  # ── Agent context bar (0x88) ──

  @doc """
  Encodes the agent context bar state when zoomed into an agent card.

  Layout:
    - visible(1): 1 if zoomed into a non-You agent card, 0 otherwise
    - task_len(2): length of task string
    - task(N): task description
    - dispatch_timestamp(8): Unix timestamp when the task was dispatched
    - status(1): current card status (0-5)
    - can_approve(1): 1 if the user can approve the agent's work, 0 otherwise
  """
  @spec encode_gui_agent_context(boolean(), String.t(), DateTime.t(), atom(), boolean()) ::
          binary()
  def encode_gui_agent_context(visible, task, dispatch_timestamp, status, can_approve) do
    visible_byte = if visible, do: 1, else: 0
    task_bytes = :erlang.iolist_to_binary([task])
    timestamp_seconds = DateTime.to_unix(dispatch_timestamp)
    status_byte = board_status_byte(status)
    can_approve_byte = if can_approve, do: 1, else: 0

    IO.iodata_to_binary([
      @op_gui_agent_context,
      <<visible_byte::8, byte_size(task_bytes)::16, task_bytes::binary, timestamp_seconds::64,
        status_byte::8, can_approve_byte::8>>
    ])
  end

  # ── Change Summary ──

  @doc """
  Encodes a gui_change_summary command (0x89).

  Sends the list of changed files with diff stats when zoomed into an agent card.
  The Swift frontend renders this as a resizable sidebar on the left.

  Wire format:
    opcode(1) + visible(1) + selected_index(2) + entry_count(2) + entries...

  Each entry:
    path_len(2) + path + action(1) + lines_added(4) + lines_removed(4)

  Action: 0=modified, 1=added, 2=deleted, 3=renamed
  """
  @spec encode_gui_change_summary([map()], non_neg_integer()) :: binary()
  def encode_gui_change_summary(entries, selected_index \\ 0) when is_list(entries) do
    visible = if entries == [], do: 0, else: 1

    entry_binaries =
      Enum.map(entries, fn entry ->
        path_bytes = :erlang.iolist_to_binary([entry.path])
        action_byte = file_action_byte(entry.action)

        <<byte_size(path_bytes)::16, path_bytes::binary, action_byte::8, entry.lines_added::32,
          entry.lines_removed::32>>
      end)

    IO.iodata_to_binary([
      <<@op_gui_change_summary, visible::8, selected_index::16, length(entries)::16>>
      | entry_binaries
    ])
  end

  @spec file_action_byte(:modified | :added | :deleted | :renamed) :: non_neg_integer()
  defp file_action_byte(:modified), do: 0
  defp file_action_byte(:added), do: 1
  defp file_action_byte(:deleted), do: 2
  defp file_action_byte(:renamed), do: 3
  defp file_action_byte(_), do: 0

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

  # ── Indent guides (forward-compatible, 0x91) ──

  @typedoc "Indent guide data for one window."
  @type indent_guide_data :: %{
          window_id: non_neg_integer(),
          tab_width: pos_integer(),
          active_guide_col: non_neg_integer(),
          guide_cols: [non_neg_integer()],
          line_indent_levels: [non_neg_integer()]
        }

  @doc """
  Encodes a gui_indent_guides command for one window.

  Uses the forward-compatible 0x90+ format: opcode(1) + payload_length(2) + payload.
  Payload: window_id(2) + tab_width(1) + active_guide_col(2) + guide_count(1) + guide_cols(2 each)
           + line_count(2) + indent_levels(1 each).

  `active_guide_col` of 0xFFFF means no active guide. Guide columns are
  character-unit offsets from the content start (not screen left).
  `line_indent_levels` gives the effective indent level per visible line so the
  frontend can draw guide segments only in whitespace, not through text.
  """
  @spec encode_gui_indent_guides(indent_guide_data()) :: binary()
  def encode_gui_indent_guides(%{
        window_id: win_id,
        tab_width: tab_width,
        active_guide_col: active_col,
        guide_cols: cols,
        line_indent_levels: levels
      }) do
    guide_count = length(cols)
    guide_bytes = for col <- cols, into: <<>>, do: <<col::16>>
    line_count = length(levels)
    level_bytes = for lvl <- levels, into: <<>>, do: <<min(lvl, 255)::8>>

    # 2 (win_id) + 1 (tab_width) + 2 (active_col) + 1 (guide_count) + 2*guide_count + 2 (line_count) + line_count
    payload_len = 6 + 2 * guide_count + 2 + line_count

    <<@op_gui_indent_guides, payload_len::16, win_id::16, tab_width::8, active_col::16,
      guide_count::8, guide_bytes::binary, line_count::16, level_bytes::binary>>
  end

  @doc """
  Encodes a gui_indent_guides command with no guides (empty).
  """
  @spec encode_gui_indent_guides_empty(non_neg_integer()) :: binary()
  def encode_gui_indent_guides_empty(win_id) do
    # payload: win_id(2) + tab_width(1) + active_col(2) + guide_count(1) = 6 bytes
    <<@op_gui_indent_guides, 6::16, win_id::16, 0::8, 0xFFFF::16, 0::8>>
  end

  # ── Line spacing (forward-compatible, 0x92) ──

  @doc """
  Encodes a gui_line_spacing command.

  Uses the forward-compatible 0x90+ format: opcode(1) + payload_length(2) + payload.
  Payload: spacing_x100(2) — the spacing multiplier times 100 as a 16-bit unsigned integer.
  For example, 1.2 is encoded as 120, 1.0 as 100.
  """
  @spec encode_gui_line_spacing(number()) :: binary()
  def encode_gui_line_spacing(spacing) when is_number(spacing) and spacing >= 1.0 do
    spacing_x100 = round(spacing * 100)
    <<@op_gui_line_spacing, 2::16, spacing_x100::16>>
  end

  # ── Cursor animation (forward-compatible, 0x95) ──

  @doc """
  Encodes a gui_cursor_animation command.

  Sends whether the GUI renderer should animate cursor movement. Reduce Motion can still disable animation on the frontend.
  Uses the forward-compatible 0x90+ format: opcode(1) + payload_length(2) + enabled(1).
  """
  @spec encode_gui_cursor_animation(boolean()) :: binary()
  def encode_gui_cursor_animation(enabled) when is_boolean(enabled) do
    enabled_byte = if enabled, do: 1, else: 0
    <<@op_gui_cursor_animation, 1::16, enabled_byte::8>>
  end

  # ── Config state (forward-compatible, 0x97) ──

  @typedoc "Theme preview swatch sent to native settings UI."
  @type theme_preview :: %{
          required(:name) => String.t(),
          required(:atom) => String.t(),
          required(:editor_bg) => non_neg_integer(),
          required(:editor_fg) => non_neg_integer(),
          required(:accent) => non_neg_integer()
        }

  @typedoc "Read-only keybinding entry sent to native settings UI."
  @type keybinding_entry :: %{
          required(:mode) => String.t(),
          required(:key) => String.t(),
          required(:command) => String.t(),
          required(:description) => String.t()
        }

  @typedoc "Settings state payload sent to native settings UI."
  @type config_state :: %{
          required(:options) => %{Options.option_name() => term()},
          required(:theme_previews) => [theme_preview()],
          required(:keybindings) => [keybinding_entry()]
        }

  @doc "Encodes the current settings panel state for native GUI frontends."
  @spec encode_gui_config_state(config_state()) :: binary()
  def encode_gui_config_state(%{
        options: options,
        theme_previews: previews,
        keybindings: bindings
      }) do
    option_entries = Enum.map(options, fn {name, value} -> encode_config_option(name, value) end)
    preview_entries = Enum.map(previews, &encode_theme_preview/1)
    binding_entries = Enum.map(bindings, &encode_keybinding_entry/1)

    payload =
      IO.iodata_to_binary([
        <<length(option_entries)::16>>,
        option_entries,
        <<length(preview_entries)::16>>,
        preview_entries,
        <<length(binding_entries)::16>>,
        binding_entries
      ])

    <<@op_gui_config_state, byte_size(payload)::16, payload::binary>>
  end

  @doc "Builds a full settings state payload from the current config and keymap servers."
  @spec config_state(Options.server(), Minga.Keymap.server()) :: config_state()
  def config_state(
        options_server \\ Options.default_server(),
        keymap_server \\ Minga.Keymap.default_server()
      ) do
    options =
      @settings_options
      |> Enum.map(fn name -> {name, Options.get(options_server, name)} end)
      |> Map.new()

    %{
      options: options,
      theme_previews: theme_previews(),
      keybindings: keybinding_entries(keymap_server)
    }
  end

  @doc "Builds a one-option settings state payload for incremental updates."
  @spec config_state_entry(Options.option_name(), term()) :: config_state()
  def config_state_entry(name, value) do
    %{options: %{name => value}, theme_previews: [], keybindings: []}
  end

  @spec settings_option?(atom()) :: boolean()
  def settings_option?(name), do: name in @settings_options

  @spec encode_config_option(Options.option_name(), term()) :: binary()
  defp encode_config_option(name, value) when is_atom(name) do
    name_bytes = Atom.to_string(name)
    value_payload = encode_config_value(value)
    <<byte_size(name_bytes)::8, name_bytes::binary, value_payload::binary>>
  end

  @spec encode_config_value(term()) :: binary()
  defp encode_config_value(value) when is_boolean(value) do
    encoded = if value, do: 1, else: 0
    <<@value_boolean::8, encoded::8>>
  end

  defp encode_config_value(value) when is_integer(value),
    do: <<@value_integer::8, value::32-signed>>

  defp encode_config_value(value) when is_binary(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<@value_string::8, byte_size(bytes)::16, bytes::binary>>
  end

  defp encode_config_value(value) when is_atom(value) do
    bytes = Atom.to_string(value)
    <<@value_atom::8, byte_size(bytes)::16, bytes::binary>>
  end

  defp encode_config_value(value) when is_float(value), do: <<@value_float::8, value::float-64>>

  defp encode_config_value(value) do
    bytes = inspect(value)
    <<@value_string::8, byte_size(bytes)::16, bytes::binary>>
  end

  @spec encode_theme_preview(theme_preview()) :: binary()
  defp encode_theme_preview(%{
         name: name,
         atom: atom,
         editor_bg: bg,
         editor_fg: fg,
         accent: accent
       }) do
    <<encode_string8(name)::binary, encode_string8(atom)::binary, bg::24, fg::24, accent::24>>
  end

  @spec theme_previews() :: [theme_preview()]
  defp theme_previews do
    MingaEditor.UI.Theme.available()
    |> Enum.map(&theme_preview/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec theme_preview(atom()) :: theme_preview() | nil
  defp theme_preview(name) do
    case MingaEditor.UI.Theme.get(name) do
      {:ok, theme} ->
        %{
          name: humanize_theme_name(name),
          atom: Atom.to_string(name),
          editor_bg: theme.editor.bg,
          editor_fg: theme.editor.fg,
          accent: theme_accent(theme)
        }

      :error ->
        nil
    end
  end

  @spec humanize_theme_name(atom()) :: String.t()
  defp humanize_theme_name(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @spec theme_accent(MingaEditor.UI.Theme.t()) :: non_neg_integer()
  defp theme_accent(%{modeline: %{filetype_fg: accent}}), do: accent

  @spec keybinding_entries(Minga.Keymap.server()) :: [keybinding_entry()]
  defp keybinding_entries(keymap_server) do
    [
      normal_keybinding_entries(keymap_server),
      leader_keybinding_entries(keymap_server),
      mode_keybinding_entries(keymap_server),
      scope_keybinding_entries(keymap_server)
    ]
    |> List.flatten()
    |> Enum.uniq_by(fn %{mode: mode, key: key, command: command} -> {mode, key, command} end)
    |> Enum.sort_by(fn %{mode: mode, key: key} -> {mode, key} end)
  end

  @spec normal_keybinding_entries(Minga.Keymap.server()) :: [keybinding_entry()]
  defp normal_keybinding_entries(keymap_server) do
    keymap_server
    |> safe_normal_bindings()
    |> Enum.map(fn {key, {command, description}} ->
      keybinding_entry("normal", [key], command, description)
    end)
  end

  @spec leader_keybinding_entries(Minga.Keymap.server()) :: [keybinding_entry()]
  defp leader_keybinding_entries(keymap_server) do
    keymap_server
    |> safe_leader_trie()
    |> trie_keybinding_entries("normal", [Minga.Keymap.Defaults.leader_key()])
  end

  @spec mode_keybinding_entries(Minga.Keymap.server()) :: [keybinding_entry()]
  defp mode_keybinding_entries(keymap_server) do
    [:insert, :visual, :operator_pending, :command]
    |> Enum.flat_map(fn mode ->
      keymap_server
      |> safe_mode_trie(mode)
      |> trie_keybinding_entries(Atom.to_string(mode), [])
    end)
  end

  @spec scope_keybinding_entries(Minga.Keymap.server()) :: [keybinding_entry()]
  defp scope_keybinding_entries(keymap_server) do
    Minga.Keymap.Scope.all_scopes()
    |> Enum.flat_map(&scope_keybinding_entries(keymap_server, &1))
  end

  @spec scope_keybinding_entries(Minga.Keymap.server(), Minga.Keymap.Scope.scope_name()) ::
          [keybinding_entry()]
  defp scope_keybinding_entries(keymap_server, scope) do
    case Minga.Keymap.Scope.module_for(scope) do
      nil ->
        []

      mod ->
        Enum.flat_map([:normal, :insert, :input_normal, :cua], fn vim_state ->
          scope_vim_keybinding_entries(keymap_server, scope, mod, vim_state)
        end)
    end
  end

  @spec scope_vim_keybinding_entries(
          Minga.Keymap.server(),
          Minga.Keymap.Scope.scope_name(),
          module(),
          atom()
        ) :: [keybinding_entry()]
  defp scope_vim_keybinding_entries(keymap_server, scope, mod, vim_state) do
    mode = "#{scope}/#{vim_state}"

    [
      mod.keymap(vim_state, []),
      mod.shared_keymap(),
      safe_scope_trie(keymap_server, scope, vim_state)
    ]
    |> Enum.flat_map(&trie_keybinding_entries(&1, mode, []))
  end

  @spec safe_normal_bindings(Minga.Keymap.server()) :: %{Bindings.key() => {atom(), String.t()}}
  defp safe_normal_bindings(keymap_server) do
    KeymapActive.normal_bindings(keymap_server)
  rescue
    ArgumentError -> Minga.Keymap.Defaults.normal_bindings()
  catch
    :exit, _ -> Minga.Keymap.Defaults.normal_bindings()
  end

  @spec safe_leader_trie(Minga.Keymap.server()) :: Bindings.node_t()
  defp safe_leader_trie(keymap_server) do
    KeymapActive.leader_trie(keymap_server)
  rescue
    ArgumentError -> Minga.Keymap.Defaults.leader_trie()
  catch
    :exit, _ -> Minga.Keymap.Defaults.leader_trie()
  end

  @spec safe_mode_trie(Minga.Keymap.server(), atom()) :: Bindings.node_t()
  defp safe_mode_trie(keymap_server, mode) do
    KeymapActive.mode_trie(keymap_server, mode)
  rescue
    ArgumentError -> Bindings.new()
  catch
    :exit, _ -> Bindings.new()
  end

  @spec safe_scope_trie(Minga.Keymap.server(), Minga.Keymap.Scope.scope_name(), atom()) ::
          Bindings.node_t()
  defp safe_scope_trie(keymap_server, scope, vim_state) do
    KeymapActive.scope_trie(keymap_server, scope, vim_state)
  rescue
    ArgumentError -> Bindings.new()
  catch
    :exit, _ -> Bindings.new()
  end

  @spec trie_keybinding_entries(Bindings.node_t(), String.t(), [Bindings.key()]) ::
          [keybinding_entry()]
  defp trie_keybinding_entries(%Bindings.Node{} = node, mode, prefix) do
    node.children
    |> Enum.flat_map(fn {key, child} ->
      sequence = prefix ++ [key]
      child_entries = trie_keybinding_entries(child, mode, sequence)

      case child.command do
        nil ->
          child_entries

        command ->
          [keybinding_entry(mode, sequence, command, child.description || "") | child_entries]
      end
    end)
  end

  @spec keybinding_entry(String.t(), [Bindings.key()], atom() | tuple(), String.t()) ::
          keybinding_entry()
  defp keybinding_entry(mode, sequence, command, description) do
    %{
      mode: mode,
      key: format_key_sequence(sequence),
      command: command_to_string(command),
      description: description
    }
  end

  @spec format_key_sequence([Bindings.key()]) :: String.t()
  defp format_key_sequence(sequence) do
    Enum.map_join(sequence, " ", &Bindings.format_key/1)
  end

  @spec command_to_string(atom() | tuple()) :: String.t()
  defp command_to_string(command) when is_atom(command), do: Atom.to_string(command)
  defp command_to_string(command), do: inspect(command)

  @spec encode_keybinding_entry(keybinding_entry()) :: binary()
  defp encode_keybinding_entry(%{mode: mode, key: key, command: command, description: desc}) do
    <<encode_string8(mode)::binary, encode_string16(key)::binary,
      encode_string16(command)::binary, encode_string16(desc)::binary>>
  end

  # ── File tree ──

  @doc """
  Encodes the semantic GUI file-tree command.

  Wire format uses a 32-bit length-prefixed envelope:

      opcode(1) + payload_len(4) + payload(payload_len)

  Payload v2:

      version(1) + tree_flags(1) + tree_state(1) + selected_id_len(2) + selected_id + root_len(2) + root + tree_width(2) + row_count(2) + error_reason_len(2) + error_reason + rows...

  Per row:

      stable_hash(4) + row_flags(2) + depth(1) + git_status(1) + diagnostics(8) + guide_count(1) + guides + id + path + rel_path + name + icon + editing_type(1) + editing_text

  String fields use uint16 byte lengths except icon, which uses a uint8 byte length.
  """
  @type file_tree_status :: FileTreeState.tree_status()

  @spec encode_gui_file_tree(String.t() | nil, non_neg_integer(), file_tree_status(), boolean(), [
          Row.t()
        ]) :: binary()
  def encode_gui_file_tree(root_path, tree_width, status, focused?, rows) when is_list(rows) do
    root = root_path || ""
    selected_id = selected_row_id(rows)
    error_reason = file_tree_error_reason(status)

    payload =
      IO.iodata_to_binary([
        <<2::8, file_tree_flags(status, focused?)::8, encode_file_tree_status(status)::8>>,
        encode_string16(selected_id),
        encode_string16(root),
        <<tree_width::16, length(rows)::16>>,
        encode_string16(error_reason),
        Enum.map(rows, &encode_file_tree_row(&1, root))
      ])

    <<@op_gui_file_tree, byte_size(payload)::32, payload::binary>>
  end

  @doc "Encodes a hidden semantic GUI file-tree command while preserving the project root."
  @spec encode_hidden_gui_file_tree(String.t() | nil) :: binary()
  def encode_hidden_gui_file_tree(root_path),
    do: encode_gui_file_tree(root_path, 0, :hidden, false, [])

  @doc "Encodes a lightweight file-tree selection update."
  @spec encode_gui_file_tree_selection(String.t(), boolean()) :: binary()
  def encode_gui_file_tree_selection(selected_id, focused?) when is_binary(selected_id) do
    payload =
      IO.iodata_to_binary([
        <<file_tree_selection_flags(focused?)::8>>,
        encode_string16(selected_id)
      ])

    <<@op_gui_file_tree_selection, byte_size(payload)::16, payload::binary>>
  end

  @spec file_tree_selection_flags(boolean()) :: non_neg_integer()
  defp file_tree_selection_flags(focused?), do: maybe_flag(0, focused?, 0)

  @spec encode_file_tree_row(Row.t(), String.t()) :: iodata()
  defp encode_file_tree_row(%Row{} = row, root) do
    icon = file_tree_row_icon(row)
    editing_type = if row.editing, do: encode_editing_type(row.editing.type), else: 0xFF
    editing_text = if row.editing, do: row.editing.text, else: ""
    guides = Enum.map(row.guides, fn guide? -> if guide?, do: <<1>>, else: <<0>> end)

    {diagnostic_errors, diagnostic_warnings, diagnostic_info, diagnostic_hints} =
      row.diagnostics
      |> FileTreeDiagnostics.to_tuple()
      |> clamp_file_tree_diagnostics()

    [
      <<:erlang.phash2(row.id, 0xFFFFFFFF)::32, file_tree_row_flags(row)::16, row.depth::8,
        encode_git_status(row.git_status)::8, diagnostic_errors::16, diagnostic_warnings::16,
        diagnostic_info::16, diagnostic_hints::16, length(row.guides)::8>>,
      guides,
      encode_string16(row.id),
      encode_string16(row.path),
      encode_string16(Path.relative_to(row.path, root)),
      encode_string16(row.name),
      encode_string8(icon),
      <<editing_type::8>>,
      encode_string16(editing_text)
    ]
  end

  @spec clamp_file_tree_diagnostics(FileTreeDiagnostics.counts()) :: FileTreeDiagnostics.counts()
  defp clamp_file_tree_diagnostics({errors, warnings, info, hints}) do
    {clamp_u16(errors), clamp_u16(warnings), clamp_u16(info), clamp_u16(hints)}
  end

  @spec clamp_u16(non_neg_integer()) :: non_neg_integer()
  defp clamp_u16(value), do: min(value, @max_u16)

  @spec selected_row_id([Row.t()]) :: String.t()
  defp selected_row_id(rows) do
    case Enum.find(rows, & &1.selected?) do
      %Row{id: id} -> id
      nil -> ""
    end
  end

  @spec file_tree_flags(FileTreeState.tree_status(), boolean()) :: non_neg_integer()
  defp file_tree_flags(status, focused?) do
    0
    |> maybe_flag(FileTreeState.visible_status?(status), 0)
    |> maybe_flag(focused?, 1)
    |> maybe_flag(status == :empty, 4)
  end

  @spec encode_file_tree_status(FileTreeState.tree_status()) :: non_neg_integer()
  defp encode_file_tree_status(:hidden), do: 0
  defp encode_file_tree_status(:loading), do: 1
  defp encode_file_tree_status(:empty), do: 2
  defp encode_file_tree_status(:ready), do: 3
  defp encode_file_tree_status({:error, _reason}), do: 4

  @spec file_tree_error_reason(FileTreeState.tree_status()) :: String.t()
  defp file_tree_error_reason({:error, reason}), do: reason
  defp file_tree_error_reason(_status), do: ""

  @spec file_tree_row_flags(Row.t()) :: non_neg_integer()
  defp file_tree_row_flags(%Row{} = row) do
    0
    |> maybe_flag(row.directory?, 0)
    |> maybe_flag(row.expanded?, 1)
    |> maybe_flag(row.selected?, 2)
    |> maybe_flag(row.focused?, 3)
    |> maybe_flag(row.active?, 4)
    |> maybe_flag(row.dirty?, 5)
    |> maybe_flag(row.editing != nil, 6)
    |> maybe_flag(row.last_child?, 7)
  end

  @spec maybe_flag(non_neg_integer(), boolean(), non_neg_integer()) :: non_neg_integer()
  defp maybe_flag(flags, true, bit), do: bor(flags, bsl(1, bit))
  defp maybe_flag(flags, false, _bit), do: flags

  @spec encode_string16(String.t()) :: binary()
  defp encode_string16(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<byte_size(bytes)::16, bytes::binary>>
  end

  @spec encode_string8(String.t()) :: binary()
  defp encode_string8(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<byte_size(bytes)::8, bytes::binary>>
  end

  @spec encode_editing_type(atom()) :: non_neg_integer()
  defp encode_editing_type(:new_file), do: 0
  defp encode_editing_type(:new_folder), do: 1
  defp encode_editing_type(:rename), do: 2

  # Nerd Font folder icon (nf-md-folder)
  @folder_icon "\u{F024B}"

  @spec file_tree_row_icon(Row.t()) :: String.t()
  defp file_tree_row_icon(%Row{directory?: true}), do: @folder_icon
  defp file_tree_row_icon(%Row{name: name}), do: Devicon.icon(Language.detect_filetype(name))

  @spec encode_git_status(atom() | nil) :: non_neg_integer()
  defp encode_git_status(nil), do: 0
  defp encode_git_status(:modified), do: 1
  defp encode_git_status(:staged), do: 2
  defp encode_git_status(:untracked), do: 3
  defp encode_git_status(:conflict), do: 4
  defp encode_git_status(:renamed), do: 5
  defp encode_git_status(:deleted), do: 6

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
    {items, selected_offset} = Minga.Editing.Completion.visible_items(comp)

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
      <<1::8, cursor_row::16, cursor_col::16, selected_offset::16, length(items)::16>>
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
  @spec encode_gui_which_key(MingaEditor.State.WhichKey.t()) :: binary()
  def encode_gui_which_key(%{show: false}), do: <<@op_gui_which_key, 0::8>>
  def encode_gui_which_key(%{show: true, node: nil}), do: <<@op_gui_which_key, 0::8>>

  def encode_gui_which_key(%{show: true, node: node, prefix_keys: prefix_keys, page: page}) do
    bindings = MingaEditor.UI.WhichKey.bindings_from_node(node)
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

  # ── Section encoding helper ──

  @doc false
  @spec encode_section(non_neg_integer(), binary()) :: binary()
  defp encode_section(section_id, payload) do
    <<section_id::8, byte_size(payload)::16, payload::binary>>
  end

  # ── Status bar (sectioned format) ──

  @doc """
  Encodes a gui_status_bar command from a `StatusBar.Data.t()` tagged union.

  Wire format (opcode 0x76, sectioned):

    [opcode:1][section_count:1][section_id:1][section_len:2][payload:N]...

  Sections are self-describing: each starts with a 1-byte ID and 2-byte
  length. Unknown sections are skipped by the frontend. New fields can be
  added without changing the decoder for existing sections.

  Section IDs:
    0x01 - Identity: content_kind, mode, flags
    0x02 - Cursor: cursor_line, cursor_col, line_count
    0x03 - Diagnostics: error/warning/info/hint counts, diagnostic_hint
    0x04 - Language: lsp_status, parser_status
    0x05 - Git: branch, added, modified, deleted
    0x06 - File: icon, icon_color, filename, filetype
    0x07 - Message: status message
    0x08 - Recording: macro_recording
    0x09 - Agent: model_name, message_count, session_status, agent_status, background_count, background_label, active_tool_name
    0x0A - Indent: indent_type, indent_size
    0x0B - ModelineSegments: named configured left/right styled modeline segments
    0x0C - Selection: selection_mode, selection_size
    0x0D - Workspace: active workspace summary
  """
  @spec encode_gui_status_bar(MingaEditor.StatusBar.Data.t()) :: binary()
  def encode_gui_status_bar(status_bar_data), do: encode_gui_status_bar(status_bar_data, nil)

  @spec encode_gui_status_bar(MingaEditor.StatusBar.Data.t(), ChromeState.t() | nil) :: binary()
  def encode_gui_status_bar({:buffer, d}, chrome_state) do
    sections = encode_status_bar_sections(d, 0, chrome_state)
    IO.iodata_to_binary([<<@op_gui_status_bar, length(sections)::8>> | sections])
  end

  def encode_gui_status_bar({:agent, d}, chrome_state) do
    sections = encode_status_bar_sections(d, 1, chrome_state)
    IO.iodata_to_binary([<<@op_gui_status_bar, length(sections)::8>> | sections])
  end

  @spec encode_status_bar_sections(map(), 0 | 1, ChromeState.t() | nil) :: [binary()]
  defp encode_status_bar_sections(d, content_kind, chrome_state) do
    mode_byte = encode_vim_mode(d.mode)
    flags = build_status_flags(d)
    lsp_byte = encode_lsp_status(d.lsp_status)
    parser_byte = encode_parser_status(d.parser_status)
    agent_byte = encode_agent_session_status(d.agent_status)
    indent_type_byte = encode_indent_type(Map.get(d, :indent_type, :spaces))
    indent_size = clamp_u8(Map.get(d, :indent_size, 2))
    {selection_mode, selection_size} = encode_selection_info(Map.get(d, :selection_info))

    git_branch = :erlang.iolist_to_binary([d.git_branch || ""])
    filetype = :erlang.iolist_to_binary([Atom.to_string(d.filetype || :text)])

    {error_count, warning_count, info_count, hint_count} = full_diagnostic_counts(d)
    macro_byte = encode_macro_recording(d.macro_recording)
    {git_added, git_modified, git_deleted} = git_diff_counts(d)
    {icon, icon_color} = MingaEditor.UI.Devicon.icon_and_color(d.filetype)
    icon_bytes = :erlang.iolist_to_binary([icon])
    icon_r = icon_color >>> 16 &&& 0xFF
    icon_g = icon_color >>> 8 &&& 0xFF
    icon_b = icon_color &&& 0xFF
    filename = :erlang.iolist_to_binary([d.file_name || ""])
    diag_hint = :erlang.iolist_to_binary([d.diagnostic_hint || ""])
    message = :erlang.iolist_to_binary([d.status_msg || ""])

    background_label =
      :erlang.iolist_to_binary([Map.get(d, :active_background_subagent_label) || ""])

    active_tool_name =
      :erlang.iolist_to_binary([Map.get(d, :active_tool_name) || ""])

    background_count = Map.get(d, :background_subagent_count, 0)

    # Shared sections (both buffer and agent variants)
    sections = [
      encode_section(@section_identity, <<content_kind::8, mode_byte::8, flags::8>>),
      encode_section(
        @section_cursor,
        <<d.cursor_line + 1::32, d.cursor_col + 1::32, d.line_count::32>>
      ),
      encode_section(
        @section_diagnostics,
        <<error_count::16, warning_count::16, info_count::16, hint_count::16,
          byte_size(diag_hint)::16, diag_hint::binary>>
      ),
      encode_section(@section_language, <<lsp_byte::8, parser_byte::8>>),
      encode_section(
        @section_git,
        <<byte_size(git_branch)::8, git_branch::binary, git_added::16, git_modified::16,
          git_deleted::16>>
      ),
      encode_section(
        @section_file,
        <<byte_size(icon_bytes)::8, icon_bytes::binary, icon_r::8, icon_g::8, icon_b::8,
          byte_size(filename)::16, filename::binary, byte_size(filetype)::8, filetype::binary>>
      ),
      encode_section(@section_message, <<byte_size(message)::16, message::binary>>),
      encode_section(@section_recording, <<macro_byte::8>>),
      encode_section(@section_indent, <<indent_type_byte::8, indent_size::8>>)
    ]

    sections = sections ++ modeline_segment_sections(Map.get(d, :modeline_segments))

    sections =
      sections ++ [encode_section(@section_selection, <<selection_mode::8, selection_size::32>>)]

    sections = sections ++ workspace_status_bar_sections(chrome_state)

    # Agent section (only when content_kind == 1)
    if content_kind == 1 do
      model_name = :erlang.iolist_to_binary([d.model_name || "Agent"])
      session_status_byte = encode_agent_session_status(d.session_status)

      sections ++
        [
          encode_section(
            @section_agent,
            <<byte_size(model_name)::8, model_name::binary, d.message_count::32,
              session_status_byte::8, agent_byte::8, background_count::16,
              byte_size(background_label)::16, background_label::binary,
              byte_size(active_tool_name)::8, active_tool_name::binary>>
          )
        ]
    else
      sections ++
        [
          encode_section(
            @section_agent,
            <<agent_byte::8, background_count::16, byte_size(background_label)::16,
              background_label::binary, byte_size(active_tool_name)::8, active_tool_name::binary>>
          )
        ]
    end
  end

  @spec workspace_status_bar_sections(ChromeState.t() | nil) :: [binary()]
  defp workspace_status_bar_sections(%ChromeState{} = chrome_state) do
    case Enum.find(chrome_state.workspaces, &(&1.id == chrome_state.active_workspace_id)) do
      %WorkspaceSummary{} = workspace ->
        [encode_section(@section_workspace, encode_status_workspace(workspace, chrome_state))]

      nil ->
        []
    end
  end

  defp workspace_status_bar_sections(nil), do: []

  @spec encode_status_workspace(WorkspaceSummary.t(), ChromeState.t()) :: binary()
  defp encode_status_workspace(%WorkspaceSummary{} = workspace, %ChromeState{} = chrome_state) do
    label_bytes = utf8_prefix_bytes(workspace.label, 255)
    icon_bytes = utf8_prefix_bytes(workspace.icon, 255)

    <<workspace.id::16, encode_workspace_kind(workspace.kind)::8,
      encode_agent_status(workspace.status)::8, encode_workspace_entry_flags(workspace)::16,
      workspace.draft_count::16, workspace.conflict_count::16,
      workspace.running_background_count::16, chrome_state.attention_count::16,
      byte_size(label_bytes)::8, label_bytes::binary, byte_size(icon_bytes)::8,
      icon_bytes::binary>>
  end

  @spec modeline_segment_sections(%{left: [tuple()], right: [tuple()]} | nil) :: [binary()]
  defp modeline_segment_sections(nil), do: []

  defp modeline_segment_sections(modeline_segments) do
    [encode_section(@section_modeline_segments, encode_modeline_segments(modeline_segments))]
  end

  @spec encode_modeline_segments(%{left: [tuple()], right: [tuple()]}) :: binary()
  defp encode_modeline_segments(%{left: left, right: right}) do
    {left, right} = capped_modeline_segments(left, right)
    {encoded_left, left_count, remaining} = bounded_modeline_side(left, @max_u16 - 5)
    {encoded_right, right_count, _remaining} = bounded_modeline_side(right, remaining)

    IO.iodata_to_binary([
      <<2::8, left_count::16, right_count::16>>,
      encoded_left,
      encoded_right
    ])
  end

  @spec capped_modeline_segments([tuple()], [tuple()]) :: {[tuple()], [tuple()]}
  defp capped_modeline_segments(left, right) do
    left = Enum.take(left, @max_modeline_segments)
    right = Enum.take(right, max(0, @max_modeline_segments - length(left)))
    {left, right}
  end

  @spec bounded_modeline_side([tuple()], non_neg_integer()) ::
          {[binary()], non_neg_integer(), non_neg_integer()}
  defp bounded_modeline_side(segments, budget) do
    Enum.reduce_while(segments, {[], 0, budget}, fn segment, {encoded, count, remaining} ->
      case encode_modeline_segment(segment, remaining) do
        {:ok, bytes} -> {:cont, {[bytes | encoded], count + 1, remaining - byte_size(bytes)}}
        :drop -> {:halt, {encoded, count, remaining}}
      end
    end)
    |> then(fn {encoded, count, remaining} -> {Enum.reverse(encoded), count, remaining} end)
  end

  @spec encode_modeline_segment(tuple(), non_neg_integer()) :: {:ok, binary()} | :drop
  defp encode_modeline_segment(_segment, remaining) when remaining < 12, do: :drop

  defp encode_modeline_segment({name, text, fg, bg, opts, target}, remaining) do
    name_bytes = modeline_name_bytes(name)
    overhead = 12 + byte_size(name_bytes)

    if remaining < overhead do
      :drop
    else
      attrs = encode_modeline_attrs(opts)
      target = encode_modeline_target(target)
      payload_budget = remaining - overhead
      {text_bytes, target_bytes} = bounded_modeline_text_and_target(text, target, payload_budget)

      {:ok,
       <<byte_size(name_bytes)::8, name_bytes::binary, fg::24, bg::24, attrs::8,
         byte_size(text_bytes)::16, text_bytes::binary, byte_size(target_bytes)::16,
         target_bytes::binary>>}
    end
  end

  defp encode_modeline_segment({text, fg, bg, opts, target}, remaining) do
    encode_modeline_segment({:custom, text, fg, bg, opts, target}, remaining)
  end

  @spec modeline_name_bytes(atom() | String.t()) :: binary()
  defp modeline_name_bytes(name) do
    name
    |> to_string()
    |> :erlang.iolist_to_binary()
    |> utf8_prefix_bytes(255)
  end

  @spec bounded_modeline_text_and_target(String.t(), String.t(), non_neg_integer()) ::
          {binary(), binary()}
  defp bounded_modeline_text_and_target(text, target, budget) do
    target_bytes = modeline_target_bytes(target, budget)
    text_budget = budget - byte_size(target_bytes)
    text_bytes = utf8_prefix_bytes(text, min(byte_size(text), text_budget))
    {text_bytes, target_bytes}
  end

  @spec modeline_target_bytes(String.t(), non_neg_integer()) :: binary()
  defp modeline_target_bytes("", _budget), do: ""

  defp modeline_target_bytes(target, budget) do
    target_bytes = :erlang.iolist_to_binary([target])

    if byte_size(target_bytes) <= budget do
      target_bytes
    else
      ""
    end
  end

  @spec encode_modeline_target(atom() | nil) :: String.t()
  defp encode_modeline_target(nil), do: ""

  defp encode_modeline_target(target), do: Atom.to_string(target)

  @spec encode_modeline_attrs(keyword()) :: non_neg_integer()
  defp encode_modeline_attrs(opts) do
    bold = if Keyword.get(opts, :bold, false), do: 0x01, else: 0x00
    underline = if Keyword.get(opts, :underline, false), do: 0x02, else: 0x00
    italic = if Keyword.get(opts, :italic, false), do: 0x04, else: 0x00
    bold ||| underline ||| italic
  end

  @spec encode_vim_mode(atom()) :: non_neg_integer()
  defp encode_vim_mode(:normal), do: 0
  defp encode_vim_mode(:insert), do: 1
  defp encode_vim_mode(:visual), do: 2
  defp encode_vim_mode(:visual_line), do: 2
  defp encode_vim_mode(:command), do: 3
  defp encode_vim_mode(:operator_pending), do: 4
  defp encode_vim_mode(:search), do: 5
  defp encode_vim_mode(:search_prompt), do: 5
  defp encode_vim_mode(:replace), do: 6
  defp encode_vim_mode(_), do: 0

  @spec encode_indent_type(atom()) :: non_neg_integer()
  defp encode_indent_type(:tabs), do: 1
  defp encode_indent_type(_indent_type), do: 0

  @spec encode_selection_info(MingaEditor.StatusBar.Data.selection_info()) ::
          {non_neg_integer(), non_neg_integer()}
  defp encode_selection_info({:chars, count}), do: {1, min(count, @max_u32)}
  defp encode_selection_info({:lines, count}), do: {2, min(count, @max_u32)}
  defp encode_selection_info(_selection_info), do: {0, 0}

  @spec clamp_u8(term()) :: non_neg_integer()
  defp clamp_u8(value) when is_integer(value), do: value |> max(0) |> min(255)
  defp clamp_u8(_value), do: 0

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
  defp encode_agent_session_status(:plan), do: 4
  defp encode_agent_session_status(_), do: 0

  # ── Picker ──

  @doc """
  Encodes a gui_picker command.

  Wire format (sectioned):
  ```
  opcode(1) + section_count(1) + sections...

  Each section:
    section_id(1) + payload_len(2) + payload(payload_len)

  Header section 0x01 payload:
    visible(1) + selected_index(2) + filtered_count(2) + total_count(2)
    + has_preview(1) + title_len(2) + title(title_len)

  Query section 0x02 payload:
    query_len(2) + query(query_len)

  Items section 0x03 payload:
    item_count(2) + items...

  Per item:
    icon_color(3) + flags(1) + label_len(2) + label + desc_len(2) + desc
    + annotation_len(2) + annotation + match_pos_count(1) + match_positions(each 2 bytes)

  ActionMenu section 0x04 payload:
    action_visible(1)
    When action_visible == 1:
      selected_action(1) + action_count(1) + actions...
      Per action: name_len(2) + name(name_len)

  ModePrefix section 0x05 payload:
    mode_prefix_len(2) + mode_prefix(mode_prefix_len)

  Flags bits:
    bit 0: two_line (file-style two-line layout)
    bit 1: marked (multi-select checkmark)
  ```
  """
  @typedoc "Action menu state: `{actions, selected_index}` or nil."
  @type action_menu_state ::
          {[{String.t(), atom()}], non_neg_integer()} | nil

  @spec encode_gui_picker(
          MingaEditor.UI.Picker.t() | nil,
          boolean(),
          action_menu_state(),
          non_neg_integer(),
          String.t()
        ) ::
          binary()
  def encode_gui_picker(
        picker,
        has_preview \\ false,
        action_menu \\ nil,
        max_items \\ 0,
        mode_prefix \\ ""
      )

  def encode_gui_picker(nil, _has_preview, _action_menu, _max_items, _mode_prefix),
    do: <<@op_gui_picker, 0::8>>

  def encode_gui_picker(
        %MingaEditor.UI.Picker{} = picker,
        has_preview,
        action_menu,
        max_items,
        mode_prefix
      ) do
    limit = if max_items > 0, do: max_items, else: picker.max_visible
    items = Enum.take(picker.filtered, limit)
    title_bytes = :erlang.iolist_to_binary([picker.title])
    query_bytes = :erlang.iolist_to_binary([picker.query])
    mode_prefix_bytes = :erlang.iolist_to_binary([mode_prefix])
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

        positions = item.match_positions
        pos_count = min(length(positions), 255)

        pos_bytes =
          Enum.take(positions, pos_count) |> Enum.map(&<<&1::16>>) |> IO.iodata_to_binary()

        <<icon_color::24, flags::8, byte_size(label_bytes)::16, label_bytes::binary,
          byte_size(desc_bytes)::16, desc_bytes::binary, byte_size(annotation_bytes)::16,
          annotation_bytes::binary, pos_count::8, pos_bytes::binary>>
      end)

    items_payload = IO.iodata_to_binary([<<length(items)::16>> | entries])
    action_menu_bytes = encode_picker_action_menu(action_menu)

    sections = [
      encode_section(
        @section_picker_header,
        <<1::8, picker.selected::16, filtered_count::16, total_count::16, has_preview_byte::8,
          byte_size(title_bytes)::16, title_bytes::binary>>
      ),
      encode_section(@section_picker_query, <<byte_size(query_bytes)::16, query_bytes::binary>>),
      encode_section(@section_picker_items, items_payload),
      encode_section(@section_picker_action_menu, action_menu_bytes),
      encode_section(
        @section_picker_mode_prefix,
        <<byte_size(mode_prefix_bytes)::16, mode_prefix_bytes::binary>>
      )
    ]

    IO.iodata_to_binary([<<@op_gui_picker, length(sections)::8>> | sections])
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

  @spec encode_picker_item_flags(MingaEditor.UI.Picker.Item.t(), MingaEditor.UI.Picker.t()) ::
          non_neg_integer()
  defp encode_picker_item_flags(item, picker) do
    two_line = if item.two_line, do: 1, else: 0
    marked = if MingaEditor.UI.Picker.marked?(picker, item), do: 1, else: 0
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
    model_bytes = utf8_prefix_bytes(model || "", @max_u16 - 2)
    prompt_bytes = utf8_prefix_bytes(prompt || "", @max_u16 - 9)

    # Prompt metadata for the cell-grid renderer (cursor, mode, line count).
    # These fields are appended after the prompt string so existing decoders
    # that stop reading after the prompt still work for the messages payload.
    prompt_line_count = data[:prompt_line_count] || 1
    prompt_cursor_line = data[:prompt_cursor_line] || 0
    prompt_cursor_col = data[:prompt_cursor_col] || 0
    prompt_vim_mode = encode_vim_mode(data[:prompt_vim_mode])
    prompt_visible_rows = data[:prompt_visible_rows] || 1

    completion_bytes = encode_prompt_completion(data[:prompt_completion])
    pending_bytes = encode_pending_approval(data[:pending_approval])
    help_bytes = encode_help_overlay(data[:help_visible], data[:help_groups])
    thinking_bytes = utf8_prefix_bytes(data[:thinking_level] || "", @max_u16 - 2)

    messages_payload = encode_chat_messages(messages)

    sections = [
      encode_section(@section_chat_header, <<1::8, status_byte::8>>),
      encode_section(@section_chat_model, <<byte_size(model_bytes)::16, model_bytes::binary>>),
      encode_section(
        @section_chat_prompt,
        <<byte_size(prompt_bytes)::16, prompt_bytes::binary, prompt_line_count::8,
          prompt_cursor_line::16, prompt_cursor_col::16, prompt_vim_mode::8,
          prompt_visible_rows::8>>
      ),
      encode_section(@section_chat_completion, completion_bytes),
      encode_section(@section_chat_pending, pending_bytes),
      encode_section(@section_chat_help, help_bytes),
      encode_section(
        @section_chat_thinking,
        <<byte_size(thinking_bytes)::16, thinking_bytes::binary>>
      ),
      encode_section(@section_chat_messages, messages_payload)
    ]

    IO.iodata_to_binary([<<@op_gui_agent_chat, length(sections)::8>> | sections])
  end

  # Encodes prompt completion popup state for @-mention or /slash completion.
  # Wire format: visible(u8) [type(u8) selected(u8) anchor_line(u16) anchor_col(u16)
  #   candidate_count(u8) [name_len(u16) name(utf8) desc_len(u16) desc(utf8)]*]
  # type: 0=mention, 1=slash
  @spec encode_prompt_completion(map() | nil) :: binary()
  defp encode_prompt_completion(nil), do: <<0::8>>

  defp encode_prompt_completion(%{type: type, candidates: candidates, selected: selected} = comp)
       when is_list(candidates) and candidates != [] do
    type_byte = if type == :slash, do: 1, else: 0
    anchor_line = comp[:anchor_line] || 0
    anchor_col = comp[:anchor_col] || 0

    candidate_bins =
      candidates
      |> Enum.take(10)
      |> Enum.map(fn
        {name, desc} ->
          n = :erlang.iolist_to_binary([name])
          d = :erlang.iolist_to_binary([desc])
          <<byte_size(n)::16, n::binary, byte_size(d)::16, d::binary>>

        name when is_binary(name) ->
          n = :erlang.iolist_to_binary([name])
          <<byte_size(n)::16, n::binary, 0::16>>
      end)

    IO.iodata_to_binary([
      <<1::8, type_byte::8, min(selected, 255)::8, anchor_line::16, anchor_col::16,
        min(length(candidates), 10)::8>>
      | candidate_bins
    ])
  end

  defp encode_prompt_completion(_), do: <<0::8>>

  @spec encode_pending_approval(map() | nil) :: binary()
  defp encode_pending_approval(nil), do: <<0::8>>

  defp encode_pending_approval(%{name: name, args: args}) do
    name_b = utf8_prefix_bytes(name, 120)
    summary_b = utf8_prefix_bytes(summarize_tool_args(name, args), @max_chat_text_bytes)
    <<1::8, byte_size(name_b)::16, name_b::binary, byte_size(summary_b)::16, summary_b::binary>>
  end

  # Encodes help overlay data: help_visible flag + optional help groups.
  # Wire format: visible(1) [workspace_count(1) [title_len(2) title(utf8)
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

  # Computes a display summary for a tool call from its name and args.
  # Reuses summarize_tool_args/2 (shared with the approval banner).
  @spec tool_call_summary(MingaAgent.ToolCall.t()) :: String.t()
  defp tool_call_summary(%MingaAgent.ToolCall{name: name, args: args}) when is_map(args) do
    summarize_tool_args(name, args)
  end

  defp tool_call_summary(%MingaAgent.ToolCall{name: name} = tc) do
    args = Map.get(tc, :args) || %{}
    summarize_tool_args(name, args)
  end

  @spec preview_kind_byte(atom()) :: non_neg_integer()
  defp preview_kind_byte(:diff), do: 1
  defp preview_kind_byte(:command), do: 2
  defp preview_kind_byte(:target), do: 3
  defp preview_kind_byte(_), do: 0

  @spec preview_text_bytes(term(), pos_integer()) :: binary()
  defp preview_text_bytes(value, max_length) when is_binary(value) do
    value |> String.slice(0, max_length) |> :erlang.iolist_to_binary()
  end

  defp preview_text_bytes(value, max_length) do
    value
    |> inspect(printable_limit: max_length)
    |> String.slice(0, max_length)
    |> :erlang.iolist_to_binary()
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

  @typedoc "A styled text run for GUI rendering: {text, fg_rgb, bg_rgb, flags} or {text, fg_rgb, bg_rgb, flags, url}."
  @type styled_run ::
          {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()}

  @typedoc "A line of styled runs."
  @type styled_line :: [styled_run()]

  @typedoc "A chat message that may carry pre-computed styled runs."
  @type gui_chat_message ::
          MingaAgent.Message.t()
          | {:styled_assistant, [[styled_run()]]}
          | {:styled_tool_call, MingaAgent.ToolCall.t(), [[styled_run()]]}
          | {:approval_tool_call, MingaAgent.ToolCall.t(), map()}

  @spec encode_chat_messages([gui_chat_message() | {pos_integer(), gui_chat_message()}]) ::
          binary()
  defp encode_chat_messages(messages) do
    messages = messages |> Enum.take(@chat_message_limit) |> Enum.map(&bound_chat_message_text/1)
    payload = encode_chat_messages_payload(messages)

    if byte_size(payload) <= @max_u16 do
      payload
    else
      stripped_messages = Enum.map(messages, &strip_chat_message_links/1)
      stripped_payload = encode_chat_messages_payload(stripped_messages)

      if byte_size(stripped_payload) <= @max_u16 do
        stripped_payload
      else
        stripped_messages
        |> fit_chat_messages_to_payload_limit()
        |> encode_chat_messages_payload()
      end
    end
  end

  @spec bound_chat_message_text(gui_chat_message() | {pos_integer(), gui_chat_message()}) ::
          gui_chat_message() | {pos_integer(), gui_chat_message()}
  defp bound_chat_message_text({id, msg}) when is_integer(id),
    do: {id, bound_chat_message_text(msg)}

  defp bound_chat_message_text({:user, text}),
    do: {:user, utf8_prefix_bytes(text, @max_chat_text_bytes)}

  defp bound_chat_message_text({:user, text, attachments}),
    do: {:user, utf8_prefix_bytes(text, @max_chat_text_bytes), attachments}

  defp bound_chat_message_text({:assistant, text}),
    do: {:assistant, utf8_prefix_bytes(text, @max_chat_text_bytes)}

  defp bound_chat_message_text({:thinking, text, collapsed}),
    do: {:thinking, utf8_prefix_bytes(text, @max_chat_text_bytes), collapsed}

  defp bound_chat_message_text({:system, text, level}),
    do: {:system, utf8_prefix_bytes(text, @max_chat_text_bytes), level}

  defp bound_chat_message_text(msg), do: msg

  @spec fit_chat_messages_to_payload_limit([
          gui_chat_message() | {pos_integer(), gui_chat_message()}
        ]) ::
          [gui_chat_message() | {pos_integer(), gui_chat_message()}]
  defp fit_chat_messages_to_payload_limit(messages) do
    {selected, omitted?} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], false}, fn msg, {selected, omitted?} ->
        candidate = [msg | selected]

        if byte_size(encode_chat_messages_payload(candidate)) <= @max_u16 do
          {candidate, omitted?}
        else
          {selected, true}
        end
      end)

    if omitted?, do: add_chat_payload_omission_notice(selected), else: selected
  end

  @spec add_chat_payload_omission_notice([
          gui_chat_message() | {pos_integer(), gui_chat_message()}
        ]) ::
          [gui_chat_message() | {pos_integer(), gui_chat_message()}]
  defp add_chat_payload_omission_notice([]) do
    [{:system, @chat_payload_omission_notice, :info}]
  end

  defp add_chat_payload_omission_notice(messages) do
    notice = {:system, @chat_payload_omission_notice, :info}

    if byte_size(encode_chat_messages_payload([notice | messages])) <= @max_u16 do
      [notice | messages]
    else
      [_dropped | rest] = messages
      add_chat_payload_omission_notice(rest)
    end
  end

  @spec encode_chat_messages_payload([gui_chat_message() | {pos_integer(), gui_chat_message()}]) ::
          binary()
  defp encode_chat_messages_payload(messages) do
    msg_binaries = Enum.map(messages, &encode_chat_message/1)

    framed_messages =
      Enum.map(msg_binaries, fn msg ->
        <<byte_size(msg)::32, msg::binary>>
      end)

    IO.iodata_to_binary([<<0xFF::8, 1::8, length(msg_binaries)::16>> | framed_messages])
  end

  @spec strip_chat_message_links(gui_chat_message() | {pos_integer(), gui_chat_message()}) ::
          gui_chat_message() | {pos_integer(), gui_chat_message()}
  defp strip_chat_message_links({id, msg}) when is_integer(id),
    do: {id, strip_chat_message_links(msg)}

  defp strip_chat_message_links({:styled_assistant, styled_lines}) do
    {:styled_assistant, strip_styled_lines_links(styled_lines)}
  end

  defp strip_chat_message_links({:styled_tool_call, tc, styled_lines}) do
    {:styled_tool_call, tc, strip_styled_lines_links(styled_lines)}
  end

  defp strip_chat_message_links(msg), do: msg

  @spec strip_styled_lines_links([[styled_run()]]) :: [[styled_run()]]
  defp strip_styled_lines_links(styled_lines) do
    Enum.map(styled_lines, fn runs -> Enum.map(runs, &strip_styled_run_link/1) end)
  end

  @spec strip_styled_run_link(styled_run()) :: styled_run()
  defp strip_styled_run_link({text, fg, bg, flags, _url}), do: {text, fg, bg, flags &&& 0xF3}
  defp strip_styled_run_link(run), do: run

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
  # run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8,
  # and when flags bit 0x08 is set: url_len::16, url.
  defp encode_chat_message_body({:styled_assistant, styled_lines}) do
    line_binaries =
      Enum.map(styled_lines, fn runs ->
        run_binaries =
          Enum.map(runs, &encode_styled_run/1)

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
    summary_bytes = utf8_prefix_bytes(tool_call_summary(tc), @max_chat_text_bytes)
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
    auto_approved_byte = auto_approved_scope_byte(tc.auto_approved_scope)

    <<0x04::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32,
      byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
      summary_bytes::binary, byte_size(result_bytes)::32, result_bytes::binary,
      auto_approved_byte::8>>
  end

  # Approval tool call: inline approval card attached to the tool message.
  # Sub-opcode 0x09. Layout:
  #   0x09, status::8, name_len::16, name, summary_len::16, summary,
  #   tool_call_id_len::16, tool_call_id, preview_kind::8,
  #   preview_line_count::16, [line_len::16, line]*
  defp encode_chat_message_body({:approval_tool_call, tc, approval}) do
    preview = Map.get(approval, :preview, MingaAgent.ToolApproval.build_preview(tc.name, tc.args))
    name_bytes = preview_text_bytes(tc.name, 120)
    summary_bytes = approval_summary_bytes(preview, tool_call_summary(tc))
    id_bytes = preview_text_bytes(Map.get(approval, :tool_call_id, tc.id), 120)

    line_binaries =
      preview
      |> Map.get(:lines, [])
      |> Enum.take(20)
      |> Enum.map(fn line ->
        bytes = preview_text_bytes(line, 1_000)
        <<byte_size(bytes)::16, bytes::binary>>
      end)

    preview_bytes = IO.iodata_to_binary(line_binaries)

    <<0x09::8, 0::8, byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
      summary_bytes::binary, byte_size(id_bytes)::16, id_bytes::binary,
      preview_kind_byte(Map.get(preview, :kind, :args))::8, length(line_binaries)::16,
      preview_bytes::binary>>
  end

  # Styled tool call: same header fields as tool_call (0x04), but result is styled runs.
  # Sub-opcode 0x08. Layout:
  #   0x08, status::8, error::8, collapsed::8, duration::32, name_len::16, name,
  #   summary_len::16, summary, line_count::16, then per line: run_count::16,
  #   then per run: text_len::16, text, fg::24, bg::24, flags::8,
  #   and when flags bit 0x08 is set: url_len::16, url. auto_approved::8 is appended after the styled line payload.
  defp encode_chat_message_body({:styled_tool_call, tc, styled_lines}) do
    name_bytes = :erlang.iolist_to_binary([tc.name])
    summary_bytes = utf8_prefix_bytes(tool_call_summary(tc), @max_chat_text_bytes)

    status_byte =
      case tc.status do
        :running -> 0
        :complete -> 1
        :error -> 2
      end

    duration = tc.duration_ms || 0
    error_byte = if tc.is_error, do: 1, else: 0
    collapsed_byte = if tc.collapsed, do: 1, else: 0
    auto_approved_byte = auto_approved_scope_byte(tc.auto_approved_scope)

    line_binaries =
      Enum.map(styled_lines, fn runs ->
        run_binaries =
          Enum.map(runs, &encode_styled_run/1)

        [<<length(runs)::16>> | run_binaries]
      end)

    IO.iodata_to_binary([
      <<0x08::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32,
        byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
        summary_bytes::binary, length(styled_lines)::16>>,
      line_binaries,
      <<auto_approved_byte::8>>
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

  @spec approval_summary_bytes(map(), String.t()) :: binary()
  defp approval_summary_bytes(%{kind: :command} = preview, fallback) do
    preview
    |> Map.get(:summary, fallback)
    |> utf8_prefix_bytes(@max_chat_text_bytes)
  end

  defp approval_summary_bytes(preview, fallback) do
    preview
    |> Map.get(:summary, fallback)
    |> utf8_prefix_bytes(300)
  end

  @spec auto_approved_scope_byte(MingaAgent.ToolCall.auto_approved_scope() | nil) :: 0 | 1 | 2
  defp auto_approved_scope_byte(:session), do: 1
  defp auto_approved_scope_byte(:turn), do: 2
  defp auto_approved_scope_byte(nil), do: 0

  @spec encode_styled_run(styled_run()) :: binary()
  defp encode_styled_run({text, fg, bg, flags, url}) do
    text_bytes = utf8_prefix_bytes(text, @max_u16)
    url_bytes = :erlang.iolist_to_binary([url])

    if byte_size(url_bytes) <= @max_u16 do
      link_flags = flags ||| 0x08

      <<byte_size(text_bytes)::16, text_bytes::binary, fg::24, bg::24, link_flags::8,
        byte_size(url_bytes)::16, url_bytes::binary>>
    else
      non_link_flags = flags &&& 0xF3
      encode_styled_run({text, fg, bg, non_link_flags})
    end
  end

  defp encode_styled_run({text, fg, bg, flags}) do
    text_bytes = utf8_prefix_bytes(text, @max_u16)
    safe_flags = flags &&& 0xF7
    <<byte_size(text_bytes)::16, text_bytes::binary, fg::24, bg::24, safe_flags::8>>
  end

  @spec utf8_prefix_bytes(String.t(), non_neg_integer()) :: binary()
  defp utf8_prefix_bytes(text, max_bytes) when byte_size(text) <= max_bytes do
    if String.valid?(text) do
      :erlang.iolist_to_binary([text])
    else
      valid_utf8_prefix(text, max_bytes)
    end
  end

  defp utf8_prefix_bytes(text, max_bytes) do
    suffix_bytes = :erlang.iolist_to_binary([@truncation_suffix])

    if max_bytes <= byte_size(suffix_bytes) do
      valid_utf8_prefix(text, max_bytes)
    else
      valid_utf8_prefix(text, max_bytes - byte_size(suffix_bytes)) <> suffix_bytes
    end
  end

  @spec valid_utf8_prefix(String.t(), non_neg_integer()) :: binary()
  defp valid_utf8_prefix(_text, 0), do: ""

  defp valid_utf8_prefix(text, max_bytes) do
    text
    |> binary_part(0, min(max_bytes, byte_size(text)))
    |> trim_invalid_utf8_suffix()
  end

  @spec trim_invalid_utf8_suffix(binary()) :: binary()
  defp trim_invalid_utf8_suffix(<<>>), do: ""

  defp trim_invalid_utf8_suffix(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      prefix |> binary_part(0, byte_size(prefix) - 1) |> trim_invalid_utf8_suffix()
    end
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

  def decode_gui_action(@gui_action_file_tree_open_in_split, <<index::16>>),
    do: {:ok, {:file_tree_open_in_split, index}}

  def decode_gui_action(@gui_action_tab_copy_path, <<id::32>>), do: {:ok, {:tab_copy_path, id}}

  def decode_gui_action(@gui_action_tab_reorder, <<id::32, new_index::16>>),
    do: {:ok, {:tab_reorder, id, new_index}}

  def decode_gui_action(@gui_action_hover_open_action, <<>>), do: {:ok, :hover_open_action}

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

  def decode_gui_action(@gui_action_file_tree_new_file, <<parent_index::16>>),
    do: {:ok, {:file_tree_new_file, parent_index}}

  def decode_gui_action(@gui_action_file_tree_new_folder, <<parent_index::16>>),
    do: {:ok, {:file_tree_new_folder, parent_index}}

  def decode_gui_action(
        @gui_action_file_tree_edit_confirm,
        <<text_len::16, text::binary-size(text_len)>>
      ),
      do: {:ok, {:file_tree_edit_confirm, text}}

  def decode_gui_action(@gui_action_file_tree_edit_cancel, <<>>),
    do: {:ok, :file_tree_edit_cancel}

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

  def decode_gui_action(
        @gui_action_git_commit,
        <<amend_byte::8, msg_len::16, message::binary-size(msg_len)>>
      )
      when amend_byte in [0, 1],
      do: {:ok, {:git_commit, message, amend_byte == 1}}

  def decode_gui_action(@gui_action_git_commit, <<msg_len::16, message::binary-size(msg_len)>>),
    do: {:ok, {:git_commit, message}}

  def decode_gui_action(@gui_action_git_open_file, <<path_len::16, path::binary-size(path_len)>>),
    do: {:ok, {:git_open_file, path}}

  def decode_gui_action(
        @gui_action_git_open_diff,
        <<path_len::16, path::binary-size(path_len), section::8>>
      )
      when section in 0..3,
      do: {:ok, {:git_open_diff, path, section}}

  def decode_gui_action(@gui_action_git_open_diff, <<path_len::16, path::binary-size(path_len)>>),
    do: {:ok, {:git_open_diff, path, 255}}

  def decode_gui_action(@gui_action_git_push, <<>>),
    do: {:ok, :git_push}

  def decode_gui_action(@gui_action_git_pull, <<>>),
    do: {:ok, :git_pull}

  def decode_gui_action(@gui_action_git_fetch, <<>>),
    do: {:ok, :git_fetch}

  def decode_gui_action(
        @gui_action_git_commit_amend,
        <<msg_len::16, message::binary-size(msg_len)>>
      ),
      do: {:ok, {:git_commit_amend, message}}

  def decode_gui_action(
        @gui_action_workspace_rename,
        <<ws_id::16, name_len::16, name::binary-size(name_len)>>
      ),
      do: {:ok, {:workspace_rename, ws_id, name}}

  def decode_gui_action(
        @gui_action_workspace_set_icon,
        <<ws_id::16, icon_len::8, icon::binary-size(icon_len)>>
      ),
      do: {:ok, {:workspace_set_icon, ws_id, icon}}

  def decode_gui_action(@gui_action_workspace_close, <<ws_id::16>>),
    do: {:ok, {:workspace_close, ws_id}}

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

  def decode_gui_action(@gui_action_board_reorder, <<card_id::32, new_index::16>>),
    do: {:ok, {:board_reorder, card_id, new_index}}

  def decode_gui_action(
        @gui_action_board_dispatch_agent,
        <<model_len::16, model::binary-size(model_len), task_len::16,
          task::binary-size(task_len)>>
      ),
      do: {:ok, {:board_dispatch_agent, task, model}}

  def decode_gui_action(@gui_action_agent_approve, <<>>),
    do: {:ok, :agent_approve}

  def decode_gui_action(@gui_action_agent_request_changes, <<>>),
    do: {:ok, :agent_request_changes}

  def decode_gui_action(@gui_action_agent_dismiss, <<>>),
    do: {:ok, :agent_dismiss}

  def decode_gui_action(@gui_action_change_summary_click, <<index::32>>),
    do: {:ok, {:change_summary_click, index}}

  def decode_gui_action(@gui_action_scroll_to_line, <<line::32>>),
    do: {:ok, {:scroll_to_line, line}}

  def decode_gui_action(@gui_action_file_tree_delete, <<index::16>>),
    do: {:ok, {:file_tree_delete, index}}

  def decode_gui_action(@gui_action_file_tree_rename, <<index::16>>),
    do: {:ok, {:file_tree_rename, index}}

  def decode_gui_action(@gui_action_file_tree_duplicate, <<index::16>>),
    do: {:ok, {:file_tree_duplicate, index}}

  def decode_gui_action(
        @gui_action_file_tree_move,
        <<source_index::16, target_dir_index::16>>
      ),
      do: {:ok, {:file_tree_move, source_index, target_dir_index}}

  def decode_gui_action(@gui_action_file_tree_drop, payload), do: decode_file_tree_drop(payload)

  def decode_gui_action(@gui_action_fold_toggle_at_line, <<window_id::16, buffer_line::32>>),
    do: {:ok, {:fold_toggle_at_line, window_id, buffer_line}}

  def decode_gui_action(@gui_action_system_will_sleep, <<>>),
    do: {:ok, :system_will_sleep}

  def decode_gui_action(@gui_action_system_did_wake, <<>>),
    do: {:ok, :system_did_wake}

  def decode_gui_action(@gui_action_power_thermal_state, <<low_power::8, thermal_state::8>>) do
    with {:ok, low_power?} <- decode_bool_byte(low_power) do
      {:ok, {:power_thermal_state, low_power?, decode_thermal_state(thermal_state)}}
    end
  end

  def decode_gui_action(@gui_action_cmd_copy, <<>>),
    do: {:ok, :cmd_copy}

  def decode_gui_action(@gui_action_cmd_cut, <<>>),
    do: {:ok, :cmd_cut}

  def decode_gui_action(@gui_action_git_pull_and_retry, <<>>),
    do: {:ok, :git_pull_and_retry}

  def decode_gui_action(@gui_action_config_query, <<>>), do: {:ok, :config_query}

  def decode_gui_action(
        @gui_action_config_update,
        <<key_len::8, key::binary-size(key_len), value_payload::binary>>
      ) do
    with {:ok, name} <- decode_existing_option_name(key),
         true <- settings_option?(name),
         {:ok, value, <<>>} <- decode_config_value(value_payload) do
      {:ok, {:config_update, name, value}}
    else
      _ -> :error
    end
  end

  def decode_gui_action(
        @gui_action_notification_dismiss,
        <<id_len::16, id::binary-size(id_len)>>
      ) do
    {:ok, {:notification_dismiss, id}}
  end

  def decode_gui_action(
        @gui_action_notification_action,
        <<id_len::16, id::binary-size(id_len), action_len::16, action::binary-size(action_len)>>
      ) do
    {:ok, {:notification_action, id, action}}
  end

  def decode_gui_action(_, _), do: :error

  @spec decode_bool_byte(non_neg_integer()) :: {:ok, boolean()} | :error
  defp decode_bool_byte(0), do: {:ok, false}
  defp decode_bool_byte(1), do: {:ok, true}
  defp decode_bool_byte(_), do: :error

  @spec decode_thermal_state(non_neg_integer()) :: thermal_state()
  defp decode_thermal_state(0), do: :nominal
  defp decode_thermal_state(1), do: :fair
  defp decode_thermal_state(2), do: :serious
  defp decode_thermal_state(3), do: :critical
  defp decode_thermal_state(value), do: {:unknown, value}

  @spec decode_existing_option_name(String.t()) :: {:ok, Options.option_name()} | :error
  defp decode_existing_option_name(key) do
    name = String.to_existing_atom(key)

    if name in Options.valid_names() do
      {:ok, name}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  @spec decode_config_value(binary()) :: {:ok, term(), binary()} | :error
  defp decode_config_value(<<@value_boolean, 0, rest::binary>>), do: {:ok, false, rest}
  defp decode_config_value(<<@value_boolean, 1, rest::binary>>), do: {:ok, true, rest}

  defp decode_config_value(<<@value_integer, value::32-signed, rest::binary>>),
    do: {:ok, value, rest}

  defp decode_config_value(<<@value_float, value::float-64, rest::binary>>),
    do: {:ok, value, rest}

  defp decode_config_value(<<@value_string, len::16, value::binary-size(len), rest::binary>>),
    do: {:ok, value, rest}

  defp decode_config_value(<<@value_atom, len::16, value::binary-size(len), rest::binary>>) do
    atom = String.to_existing_atom(value)
    {:ok, atom, rest}
  rescue
    ArgumentError -> :error
  end

  defp decode_config_value(_payload), do: :error

  @spec decode_file_tree_drop(binary()) :: {:ok, {:file_tree_drop, DropIntent.t()}} | :error
  defp decode_file_tree_drop(
         <<target_index::16, target_path_hash::32, target_kind::8, modifiers::8, rest::binary>>
       ) do
    with {:ok, target_dir?} <- decode_drop_target_kind(target_kind),
         {:ok, target_id, rest} <- decode_string16(rest),
         {:ok, target_path, rest} <- decode_string16(rest),
         <<source_count::16, sources_binary::binary>> <- rest,
         {:ok, source_paths, <<>>} <- decode_string16_list(sources_binary, source_count) do
      {:ok,
       {:file_tree_drop,
        DropIntent.new(
          source_paths: source_paths,
          target_index: target_index,
          target_id: target_id,
          target_path_hash: target_path_hash,
          target_path: target_path,
          target_dir?: target_dir?,
          modifiers: modifiers
        )}}
    else
      _ -> :error
    end
  end

  defp decode_file_tree_drop(_payload), do: :error

  @spec decode_drop_target_kind(non_neg_integer()) :: {:ok, boolean()} | :error
  defp decode_drop_target_kind(1), do: {:ok, true}
  defp decode_drop_target_kind(0), do: {:ok, false}
  defp decode_drop_target_kind(_kind), do: :error

  @spec decode_string16(binary()) :: {:ok, String.t(), binary()} | :error

  defp decode_string16(<<len::16, value::binary-size(len), rest::binary>>) do
    if String.valid?(value), do: {:ok, value, rest}, else: :error
  end

  defp decode_string16(_payload), do: :error

  @spec decode_string16_list(binary(), non_neg_integer()) ::
          {:ok, [String.t()], binary()} | :error
  defp decode_string16_list(rest, 0), do: {:ok, [], rest}

  defp decode_string16_list(payload, count) when count > 0 do
    with {:ok, value, rest} <- decode_string16(payload),
         {:ok, values, rest} <- decode_string16_list(rest, count - 1) do
      {:ok, [value | values], rest}
    else
      _ -> :error
    end
  end

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
    standard: style(1) + text_len(2) + text(text_len)
    syntaxHighlighted: style(1=13) + fg_r(1) + fg_g(1) + fg_b(1) + flags(1) + text_len(2) + text(text_len)

  Line types: 0=text, 1=code, 2=code_header, 3=header, 4=blockquote,
    5=list_item, 6=rule, 7=empty

  Segment styles: 0=plain, 1=bold, 2=italic, 3=bold_italic,
    4=code, 5=code_block, 6=code_content, 7=header1, 8=header2, 9=header3,
    10=blockquote, 11=list_bullet, 12=rule, 13=syntaxHighlighted
  """
  @spec encode_gui_hover_popup(MingaEditor.HoverPopup.t() | nil) :: binary()
  def encode_gui_hover_popup(nil), do: <<@op_gui_hover_popup, 0::8>>

  def encode_gui_hover_popup(%MingaEditor.HoverPopup{content_lines: []}) do
    <<@op_gui_hover_popup, 0::8>>
  end

  def encode_gui_hover_popup(%MingaEditor.HoverPopup{} = popup) do
    focused_byte = if popup.focused, do: 1, else: 0

    line_data =
      Enum.map(popup.content_lines, fn {segments, line_type} ->
        line_type_byte = encode_line_type(line_type)

        segment_data = Enum.map(segments, &encode_markdown_segment/1)

        [<<line_type_byte::8, length(segments)::16>> | segment_data]
      end)

    hover =
      IO.iodata_to_binary([
        <<@op_gui_hover_popup, 1::8, popup.anchor_row::16, popup.anchor_col::16, focused_byte::8,
          popup.scroll_offset::16, length(popup.content_lines)::16>>
        | line_data
      ])

    IO.iodata_to_binary([hover, encode_gui_hover_action(popup)])
  end

  @doc "Encodes optional hover popup action metadata as a forward-compatible sidecar command."
  @spec encode_gui_hover_action(MingaEditor.HoverPopup.t() | nil) :: binary()
  def encode_gui_hover_action(nil), do: <<@op_gui_hover_action, 1::16, 0::8>>

  def encode_gui_hover_action(%MingaEditor.HoverPopup{open_action: nil}) do
    <<@op_gui_hover_action, 1::16, 0::8>>
  end

  def encode_gui_hover_action(%MingaEditor.HoverPopup{open_action: action}) do
    action_bytes =
      action |> MingaEditor.HoverPopup.open_action_name() |> :erlang.iolist_to_binary()

    payload_len = 1 + 2 + byte_size(action_bytes)

    <<@op_gui_hover_action, payload_len::16, 1::8, byte_size(action_bytes)::16,
      action_bytes::binary>>
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
  @spec encode_gui_signature_help(MingaEditor.SignatureHelp.t() | nil) :: binary()
  def encode_gui_signature_help(nil), do: <<@op_gui_signature_help, 0::8>>

  def encode_gui_signature_help(%MingaEditor.SignatureHelp{signatures: []}) do
    <<@op_gui_signature_help, 0::8>>
  end

  def encode_gui_signature_help(%MingaEditor.SignatureHelp{} = sh) do
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

  # ── Notifications ──

  @doc """
  Encodes the full GUI notification center snapshot.

  Wire format (opcode 0x99):
    opcode(1) + payload_len(2) + version(1) + count(2) + notifications...

  Each notification:
    id + level(1) + flags(1) + created_at(8) + updated_at(8) + auto_dismiss_ms(4) + title + body + source + action_count(1) + actions...

  Strings are u16 length-prefixed. `auto_dismiss_ms` uses 0xFFFFFFFF for nil.
  """
  @max_notification_title_bytes 512
  @max_notification_body_bytes 8_192
  @max_notification_source_bytes 512
  @max_notification_action_label_bytes 512

  @spec encode_gui_notifications(NotificationCenter.t()) :: binary()
  def encode_gui_notifications(%NotificationCenter{} = center) do
    {notification_bins, count} = bounded_notification_bins(center.items)
    payload = IO.iodata_to_binary([<<1::8, count::16>>, notification_bins])
    <<@op_gui_notifications, byte_size(payload)::16, payload::binary>>
  end

  @spec bounded_notification_bins([Notification.t()]) :: {[binary()], non_neg_integer()}
  defp bounded_notification_bins(notifications) do
    notifications
    |> Enum.take(@max_u16)
    |> Enum.reduce_while({[], 0, 3}, fn notification, {bins, count, size} ->
      bin = encode_notification(notification)
      next_size = size + byte_size(bin)

      if next_size <= @max_u16 do
        {:cont, {[bin | bins], count + 1, next_size}}
      else
        {:halt, {bins, count, size}}
      end
    end)
    |> then(fn {bins, count, _size} -> {Enum.reverse(bins), count} end)
  end

  @spec encode_notification(Notification.t()) :: binary()
  defp encode_notification(%Notification{} = notification) do
    flags = if notification.dismissable, do: 0x01, else: 0x00
    auto_dismiss_ms = notification.auto_dismiss_ms || @max_u32
    updated_at = notification.updated_at || notification.created_at
    actions = Enum.take(notification.actions, @max_u8)

    IO.iodata_to_binary([
      encode_notification_string16(notification.id, @max_notification_title_bytes),
      <<notification_level_byte(notification.level)::8, flags::8, notification.created_at::64,
        updated_at::64, auto_dismiss_ms::32>>,
      encode_notification_string16(notification.title, @max_notification_title_bytes),
      encode_notification_string16(notification.body || "", @max_notification_body_bytes),
      encode_notification_string16(notification.source || "", @max_notification_source_bytes),
      <<length(actions)::8>>,
      Enum.map(actions, &encode_notification_action/1)
    ])
  end

  @spec encode_notification_action(Notification.Action.t()) :: binary()
  defp encode_notification_action(%Notification.Action{} = action) do
    IO.iodata_to_binary([
      encode_notification_string16(action.id, @max_notification_title_bytes),
      encode_notification_string16(action.label, @max_notification_action_label_bytes)
    ])
  end

  @spec encode_notification_string16(String.t(), non_neg_integer()) :: binary()
  defp encode_notification_string16(text, max_bytes) when is_binary(text) do
    bytes = utf8_prefix_bytes(text, min(max_bytes, @max_u16))
    <<byte_size(bytes)::16, bytes::binary>>
  end

  @spec notification_level_byte(Notification.level()) :: non_neg_integer()
  defp notification_level_byte(:info), do: 0
  defp notification_level_byte(:warning), do: 1
  defp notification_level_byte(:error), do: 2
  defp notification_level_byte(:success), do: 3
  defp notification_level_byte(:progress), do: 4

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

  @typedoc "Git toast action for error recovery."
  @type git_toast_action :: :pull_and_retry | nil

  @typedoc "Git toast data shown after a remote operation completes."
  @type git_toast :: %{
          required(:message) => String.t(),
          required(:level) => :success | :error,
          required(:action) => git_toast_action(),
          optional(:dismiss_ref) => reference()
        }

  @typedoc "Base git status data stored on the panel (without emit-time fields)."
  @type git_status_panel_data :: %{
          repo_state: :normal | :not_a_repo | :loading,
          branch: String.t(),
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          entries: [Minga.Git.StatusEntry.t()],
          entry_base_path: String.t(),
          last_commit_message: String.t()
        }

  @typedoc "Git status data enriched with syncing/toast for protocol encoding."
  @type git_status_data :: %{
          repo_state: :normal | :not_a_repo | :loading,
          syncing: boolean(),
          branch: String.t(),
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          entries: [Minga.Git.StatusEntry.t()],
          entry_base_path: String.t(),
          last_commit_message: String.t(),
          git_toast: git_toast() | nil
        }

  @doc """
  Encodes a gui_git_status command (0x85) for the native GUI frontend.

  Wire format:
    opcode:1, repo_state:1, syncing:1, ahead:2, behind:2, branch_len:2, branch,
    entry_count:2, then per entry:
      path_hash:4, section:1, status:1, path_len:2, path
    then toast section:
      toast_present:1, [toast_level:1, action:1, msg_len:2, msg]
    then repo metadata:
      entry_base_path_len:2, entry_base_path, last_commit_message_len:2, last_commit_message
  """
  @spec encode_gui_git_status(git_status_data()) :: binary()
  def encode_gui_git_status(
        %{
          repo_state: repo_state,
          syncing: syncing,
          branch: branch,
          ahead: ahead,
          behind: behind,
          entries: entries
        } = data
      ) do
    repo_state_byte = encode_repo_state(repo_state)
    syncing_byte = bool_to_byte(syncing)
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

    toast_binary = encode_git_toast(Map.get(data, :git_toast))

    entry_base_path_bytes =
      utf8_prefix_bytes(
        Map.get(data, :entry_base_path) || Map.get(data, :git_root) || "",
        @max_u16
      )

    last_commit_message_bytes =
      utf8_prefix_bytes(Map.get(data, :last_commit_message) || "", @max_u16)

    IO.iodata_to_binary([
      <<@op_gui_git_status, repo_state_byte::8, syncing_byte::8, ahead::16, behind::16,
        byte_size(branch_bytes)::16, branch_bytes::binary, entry_count::16>>,
      entry_binaries,
      toast_binary,
      <<byte_size(entry_base_path_bytes)::16, entry_base_path_bytes::binary,
        byte_size(last_commit_message_bytes)::16, last_commit_message_bytes::binary>>
    ])
  end

  @spec bool_to_byte(boolean()) :: 0 | 1
  defp bool_to_byte(true), do: 1
  defp bool_to_byte(false), do: 0

  @spec encode_git_toast(git_toast() | nil) :: binary()
  defp encode_git_toast(nil), do: <<0::8>>

  defp encode_git_toast(%{message: message, level: level, action: action}) do
    level_byte = encode_toast_level(level)
    action_byte = encode_toast_action(action)
    msg_bytes = :erlang.iolist_to_binary([message])
    <<1::8, level_byte::8, action_byte::8, byte_size(msg_bytes)::16, msg_bytes::binary>>
  end

  @spec encode_toast_level(:success | :error) :: non_neg_integer()
  defp encode_toast_level(:success), do: 0
  defp encode_toast_level(:error), do: 1

  @spec encode_toast_action(git_toast_action()) :: non_neg_integer()
  defp encode_toast_action(nil), do: 0
  defp encode_toast_action(:pull_and_retry), do: 1

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

  @syntax_fallback_fg 0xBBC2CF

  @spec encode_markdown_segment(MingaAgent.Markdown.segment()) :: binary()
  defp encode_markdown_segment({text, {:syntax, %Minga.Core.Face{} = face}}) do
    text_bytes = :erlang.iolist_to_binary([text])
    fg = face.fg || @syntax_fallback_fg
    flags = encode_syntax_flags(face)

    <<13::8, red(fg)::8, green(fg)::8, blue(fg)::8, flags::8, byte_size(text_bytes)::16,
      text_bytes::binary>>
  end

  defp encode_markdown_segment({text, style}) do
    style_byte = encode_markdown_style(style)
    text_bytes = :erlang.iolist_to_binary([text])
    <<style_byte::8, byte_size(text_bytes)::16, text_bytes::binary>>
  end

  @spec encode_syntax_flags(Minga.Core.Face.t()) :: non_neg_integer()
  defp encode_syntax_flags(%Minga.Core.Face{} = face) do
    bold = if face.bold, do: 0x01, else: 0
    italic = if face.italic, do: 0x02, else: 0
    underline = if face.underline, do: 0x04, else: 0
    bold + italic + underline
  end

  @spec red(non_neg_integer()) :: non_neg_integer()
  defp red(rgb), do: rgb >>> 16 &&& 0xFF

  @spec green(non_neg_integer()) :: non_neg_integer()
  defp green(rgb), do: rgb >>> 8 &&& 0xFF

  @spec blue(non_neg_integer()) :: non_neg_integer()
  defp blue(rgb), do: rgb &&& 0xFF

  @spec encode_markdown_style(MingaAgent.Markdown.style()) :: non_neg_integer()
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

  @spec encode_line_type(MingaAgent.Markdown.line_type()) :: non_neg_integer()
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
