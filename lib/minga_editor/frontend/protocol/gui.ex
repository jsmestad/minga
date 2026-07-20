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
  | 0x7F   | gui_minibuffer  | Native minibuffer + candidates|
  | 0x81   | gui_hover_popup | Native hover tooltip popup    |
  | 0x82   | gui_signature_help | Signature help popup       |
  | 0x83   | gui_float_popup | Float popup window            |
  | 0x84   | gui_split_separators | Split pane separator lines |
  | 0x85   | gui_git_status       | Git status panel data      |
  | 0x98   | gui_workspaces    | Canonical workspace state |
  | 0x97   | gui_config_state    | Settings panel state       |
  | 0x9E   | gui_search_state    | Search toolbar state       |
  | 0x9F   | gui_sidebars        | Semantic sidebar metadata  |
  | 0xA3   | gui_extension_runtime | Generic extension-owned frontend runtime envelope |

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
  | 0x49       | tab_pin                 |
  | 0x4A       | tab_unpin               |
  | 0x4B       | tab_move_left           |
  | 0x4C       | tab_move_right          |
  | 0x4D       | observatory_inspect     |
  | 0x4E       | font_size_adjust        |
  | 0x4F       | timeline_navigate       |
  | 0x50       | extension_panel_action  |
  | 0x51       | search_query            |
  | 0x52       | search_next             |
  | 0x53       | search_prev             |
  | 0x54       | search_replace          |
  | 0x55       | search_replace_all      |
  | 0x56       | search_dismiss          |
  | 0x57       | sidebar_action          |
  | 0x58       | extension_action        |
  | 0x34       | system_will_sleep       |
  | 0x35       | system_did_wake         |
  | 0x5A       | system_will_unmount     |
  | 0x5C       | chat_scrolled_away_from_bottom |
  | 0x5D       | chat_returned_to_bottom |
  | 0x5F       | picker_query_changed    |

  """

  import Bitwise

  alias Minga.Config.Options
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings
  alias MingaEditor.FileTree.DropIntent

  alias Minga.Protocol.Opcodes

  @op_clipboard_write Opcodes.clipboard_write()
  @op_gui_extension_runtime Opcodes.gui_extension_runtime()

  @gui_action_select_tab Opcodes.gui_action_select_tab()
  @gui_action_close_tab Opcodes.gui_action_close_tab()
  @gui_action_empty_state_activate Opcodes.gui_action_empty_state_activate()
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
  @gui_action_system_will_unmount Opcodes.gui_action_system_will_unmount()
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
  @gui_action_tab_pin Opcodes.gui_action_tab_pin()
  @gui_action_tab_unpin Opcodes.gui_action_tab_unpin()
  @gui_action_tab_move_left Opcodes.gui_action_tab_move_left()
  @gui_action_tab_move_right Opcodes.gui_action_tab_move_right()
  @gui_action_file_tree_drop Opcodes.gui_action_file_tree_drop()
  @gui_action_fold_toggle_at_line Opcodes.gui_action_fold_toggle_at_line()
  @gui_action_git_open_diff Opcodes.gui_action_git_open_diff()
  @gui_action_config_update Opcodes.gui_action_config_update()
  @gui_action_config_query Opcodes.gui_action_config_query()
  @gui_action_notification_dismiss Opcodes.gui_action_notification_dismiss()
  @gui_action_notification_action Opcodes.gui_action_notification_action()
  @gui_action_observatory_inspect Opcodes.gui_action_observatory_inspect()
  @gui_action_font_size_adjust Opcodes.gui_action_font_size_adjust()
  @gui_action_timeline_navigate Opcodes.gui_action_timeline_navigate()
  @gui_action_extension_panel_action Opcodes.gui_action_extension_panel_action()
  @gui_action_extension_action Opcodes.gui_action_extension_action()
  @gui_action_float_popup_dismiss Opcodes.gui_action_float_popup_dismiss()
  @gui_action_chat_scrolled_away_from_bottom Opcodes.gui_action_chat_scrolled_away_from_bottom()
  @gui_action_chat_returned_to_bottom Opcodes.gui_action_chat_returned_to_bottom()
  @gui_action_picker_query_changed Opcodes.gui_action_picker_query_changed()
  @gui_action_search_query Opcodes.gui_action_search_query()
  @gui_action_search_next Opcodes.gui_action_search_next()
  @gui_action_search_prev Opcodes.gui_action_search_prev()
  @gui_action_search_replace Opcodes.gui_action_search_replace()
  @gui_action_search_replace_all Opcodes.gui_action_search_replace_all()
  @gui_action_search_dismiss Opcodes.gui_action_search_dismiss()
  @gui_action_sidebar_action Opcodes.gui_action_sidebar_action()

  @search_flag_replace_mode 0x01
  @search_flag_case_sensitive 0x02
  @search_flag_whole_word 0x04
  @search_flag_regex 0x08

  @typedoc "macOS thermal pressure level reported by the native GUI frontend."
  @type thermal_state :: :nominal | :fair | :serious | :critical | {:unknown, non_neg_integer()}

  # ── Sectioned format section IDs ──
  # Used by opcodes that encode their fields in self-describing sections.
  # Format: section_id(1) + section_len(2, big-endian) + payload(section_len)
  # Unknown sections are skipped by reading the length. See #1228.

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

  # ── Types ──

  @typedoc "A semantic GUI action from the Swift/GTK frontend."
  @type gui_action ::
          {:select_tab, id :: pos_integer()}
          | {:close_tab, id :: pos_integer()}
          | {:empty_state_activate, item_id :: String.t()}
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
          | {:agent_tool_toggle, message_id :: non_neg_integer()}
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
          | {:tab_pin, id :: pos_integer()}
          | {:tab_unpin, id :: pos_integer()}
          | {:tab_move_left, id :: pos_integer()}
          | {:tab_move_right, id :: pos_integer()}
          | :hover_open_action
          | :system_will_sleep
          | :system_did_wake
          | {:system_will_unmount, volume_path :: String.t()}
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
          | {:observatory_inspect, pid_string :: String.t()}
          | {:font_size_adjust, direction :: :decrease | :increase | :reset}
          | {:picker_query_changed, generation :: non_neg_integer(),
             edit_seq :: non_neg_integer(), query :: String.t()}
          | {:search_query, query :: String.t(), flags :: non_neg_integer()}
          | :search_next
          | :search_prev
          | {:search_replace, replacement :: String.t()}
          | {:search_replace_all, replacement :: String.t()}
          | :search_dismiss
          | {:sidebar_action, sidebar_id :: String.t(), kind :: String.t(), action :: String.t()}
          | {:extension_panel_action, ext_name :: String.t(), action_name :: String.t(),
             context :: map()}
          | {:extension_action, extension_id :: String.t(), action :: String.t(),
             payload :: binary()}
          | :float_popup_dismiss
          | :chat_scrolled_away_from_bottom
          | :chat_returned_to_bottom

  # ═══════════════════════════════════════════════════════════════════════════
  # Encoding (BEAM → Frontend)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Encodes a generic frontend-extension runtime message.

  Shared protocol owns only the envelope. The named frontend extension owns the payload schema and decoder.

  Format: opcode(1) + payload_length(4) + extension_id_len(2) + extension_id + channel_len(2) + channel + payload.
  """
  @spec encode_gui_extension_runtime(String.t(), String.t(), binary()) :: binary()
  def encode_gui_extension_runtime(extension_id, channel, payload)
      when is_binary(extension_id) and is_binary(channel) and is_binary(payload) do
    envelope =
      <<byte_size(extension_id)::16, extension_id::binary, byte_size(channel)::16,
        channel::binary, payload::binary>>

    <<@op_gui_extension_runtime, byte_size(envelope)::32, envelope::binary>>
  end

  # ── Clipboard write (forward-compatible, 0x90+) ──

  @typedoc "Clipboard target for the write opcode."
  @type clipboard_target :: :general | :find

  @doc """
  Encodes a clipboard_write command.

  Uses the forward-compatible 0x90+ format: opcode(1) + payload_length(4) + payload.
  Payload: target(1) + text_length(4) + text(text_length).

  Target: 0 = general pasteboard (Cmd+C), 1 = find pasteboard (Cmd+E).
  """
  @spec encode_clipboard_write(String.t(), clipboard_target()) :: binary()
  def encode_clipboard_write(text, target \\ :general) do
    target_byte = if target == :find, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    text_len = byte_size(text_bytes)
    payload_len = 1 + 4 + text_len

    <<@op_clipboard_write, payload_len::32, target_byte::8, text_len::32, text_bytes::binary>>
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

  @spec settings_option?(atom()) :: boolean()
  def settings_option?(name), do: name in @settings_options

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
      sequence = Enum.concat(prefix, [key])
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

  # ── Completion ──
  #
  # The gui_completion parity oracle (encode_gui_completion/encode_completion_kind)
  # was removed once the production CompletionEncoder migrated to the
  # schema-generated codec (#2225): the cross-language golden tests now prove
  # byte-exactness, which is the only role this oracle served.

  # ── Breadcrumb ──
  #
  # The gui_breadcrumb parity oracle (encode_gui_breadcrumb/2) was removed once
  # the production BreadcrumbEncoder migrated to the schema-generated codec
  # (#2225): the cross-language golden tests now prove byte-exactness, which is
  # the only role this oracle served.

  # ── Picker ──
  #
  # The gui_picker and gui_picker_preview parity oracles (encode_gui_picker/6,
  # encode_gui_picker_preview/1, and their private section/flag/load-status
  # helpers) were removed once the production PickerEncoder migrated to the
  # schema-generated codec (#2225): the cross-language golden tests now prove
  # byte-exactness, which is the only role these oracles served.

  # ═══════════════════════════════════════════════════════════════════════════
  # Decoding (Frontend → BEAM)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc "Unpacks a search flags byte into a keyword list of booleans."
  @spec decode_search_flags(non_neg_integer()) :: [
          replace_mode: boolean(),
          case_sensitive: boolean(),
          whole_word: boolean(),
          regex: boolean()
        ]
  def decode_search_flags(flags) when is_integer(flags) do
    [
      replace_mode: (flags &&& @search_flag_replace_mode) != 0,
      case_sensitive: (flags &&& @search_flag_case_sensitive) != 0,
      whole_word: (flags &&& @search_flag_whole_word) != 0,
      regex: (flags &&& @search_flag_regex) != 0
    ]
  end

  @doc """
  Decodes a GUI action sub-opcode and its payload into a `gui_action()` tuple.

  Called from `Protocol.decode_event/1` when the outer opcode is `0x07` (gui_action).
  """
  @spec decode_gui_action(non_neg_integer(), binary()) :: {:ok, gui_action()} | :error
  def decode_gui_action(@gui_action_select_tab, <<id::32>>), do: {:ok, {:select_tab, id}}
  def decode_gui_action(@gui_action_close_tab, <<id::32>>), do: {:ok, {:close_tab, id}}

  def decode_gui_action(@gui_action_empty_state_activate, <<len::8, id::binary-size(len)>>),
    do: {:ok, {:empty_state_activate, id}}

  def decode_gui_action(@gui_action_file_tree_click, <<index::16>>),
    do: {:ok, {:file_tree_click, index}}

  def decode_gui_action(@gui_action_file_tree_toggle, <<index::16>>),
    do: {:ok, {:file_tree_toggle, index}}

  def decode_gui_action(@gui_action_file_tree_open_in_split, <<index::16>>),
    do: {:ok, {:file_tree_open_in_split, index}}

  def decode_gui_action(@gui_action_tab_copy_path, <<id::32>>), do: {:ok, {:tab_copy_path, id}}

  def decode_gui_action(@gui_action_tab_reorder, <<id::32, new_index::16>>),
    do: {:ok, {:tab_reorder, id, new_index}}

  def decode_gui_action(@gui_action_tab_pin, <<id::32>>), do: {:ok, {:tab_pin, id}}
  def decode_gui_action(@gui_action_tab_unpin, <<id::32>>), do: {:ok, {:tab_unpin, id}}
  def decode_gui_action(@gui_action_tab_move_left, <<id::32>>), do: {:ok, {:tab_move_left, id}}
  def decode_gui_action(@gui_action_tab_move_right, <<id::32>>), do: {:ok, {:tab_move_right, id}}

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

  def decode_gui_action(@gui_action_agent_tool_toggle, <<message_id::32>>),
    do: {:ok, {:agent_tool_toggle, message_id}}

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

  def decode_gui_action(
        @gui_action_system_will_unmount,
        <<path_len::16, path::binary-size(path_len)>>
      ),
      do: {:ok, {:system_will_unmount, path}}

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

  def decode_gui_action(
        @gui_action_observatory_inspect,
        <<pid_len::16, pid_string::binary-size(pid_len)>>
      ) do
    {:ok, {:observatory_inspect, pid_string}}
  end

  def decode_gui_action(@gui_action_font_size_adjust, <<0x00>>),
    do: {:ok, {:font_size_adjust, :decrease}}

  def decode_gui_action(@gui_action_font_size_adjust, <<0x01>>),
    do: {:ok, {:font_size_adjust, :increase}}

  def decode_gui_action(@gui_action_font_size_adjust, <<0x02>>),
    do: {:ok, {:font_size_adjust, :reset}}

  def decode_gui_action(@gui_action_timeline_navigate, <<index::16>>),
    do: {:ok, {:timeline_navigate, index}}

  def decode_gui_action(
        @gui_action_extension_panel_action,
        <<ext_len::8, ext_name::binary-size(ext_len), action_len::8,
          action_name::binary-size(action_len), context_rest::binary>>
      ) do
    context = decode_panel_action_context(context_rest)
    {:ok, {:extension_panel_action, ext_name, action_name, context}}
  end

  def decode_gui_action(
        @gui_action_picker_query_changed,
        <<generation::32, edit_seq::32, query_len::16, query::binary-size(query_len)>>
      ) do
    {:ok, {:picker_query_changed, generation, edit_seq, query}}
  end

  def decode_gui_action(
        @gui_action_search_query,
        <<query_len::16, query::binary-size(query_len), flags::8>>
      ) do
    {:ok, {:search_query, query, flags}}
  end

  def decode_gui_action(@gui_action_search_next, <<>>), do: {:ok, :search_next}

  def decode_gui_action(@gui_action_search_prev, <<>>), do: {:ok, :search_prev}

  def decode_gui_action(
        @gui_action_search_replace,
        <<replacement_len::16, replacement::binary-size(replacement_len)>>
      ) do
    {:ok, {:search_replace, replacement}}
  end

  def decode_gui_action(
        @gui_action_search_replace_all,
        <<replacement_len::16, replacement::binary-size(replacement_len)>>
      ) do
    {:ok, {:search_replace_all, replacement}}
  end

  def decode_gui_action(@gui_action_search_dismiss, <<>>), do: {:ok, :search_dismiss}

  def decode_gui_action(@gui_action_sidebar_action, payload), do: decode_sidebar_action(payload)

  def decode_gui_action(@gui_action_extension_action, payload),
    do: decode_extension_action(payload)

  def decode_gui_action(@gui_action_float_popup_dismiss, <<>>), do: {:ok, :float_popup_dismiss}

  def decode_gui_action(@gui_action_chat_scrolled_away_from_bottom, <<>>),
    do: {:ok, :chat_scrolled_away_from_bottom}

  def decode_gui_action(@gui_action_chat_returned_to_bottom, <<>>),
    do: {:ok, :chat_returned_to_bottom}

  def decode_gui_action(_, _), do: :error

  @spec decode_sidebar_action(binary()) :: {:ok, gui_action()} | :error
  defp decode_sidebar_action(
         <<id_len::16, sidebar_id::binary-size(id_len), kind_len::16, kind::binary-size(kind_len),
           action_len::16, action::binary-size(action_len)>>
       ) do
    {:ok, {:sidebar_action, sidebar_id, kind, action}}
  end

  defp decode_sidebar_action(_payload), do: :error

  @spec decode_extension_action(binary()) :: {:ok, gui_action()} | :error
  defp decode_extension_action(
         <<extension_len::16, extension_id::binary-size(extension_len), action_len::16,
           action::binary-size(action_len), payload::binary>>
       ) do
    {:ok, {:extension_action, extension_id, action, payload}}
  end

  defp decode_extension_action(_payload), do: :error

  @spec decode_panel_action_context(binary()) :: map()
  defp decode_panel_action_context(<<0x01, index::16, _rest::binary>>), do: %{index: index}

  defp decode_panel_action_context(<<0x02, id_len::8, id::binary-size(id_len), _rest::binary>>),
    do: %{node_id: id}

  defp decode_panel_action_context(_), do: %{}

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

  # ── Git status panel (0x85) ──
  #
  # The gui_git_status parity oracle (encode_gui_git_status/1, its repo-state/
  # section/status/toast encode helpers, and the encode-only git_status_data/
  # git_status_panel_data types) was removed once the production GitStatusEncoder
  # migrated to the schema-generated codec (#2225): the cross-language golden
  # tests now prove byte-exactness, which is the only role this oracle served.
  # The git_status decode path (decode_gui_action) is unrelated and remains.
  #
  # The git_toast/git_toast_action types stay: they are the canonical shape for
  # git toast data carried by the production emit context and traditional shell
  # state, not an artifact of the deleted oracle.

  @typedoc "Git toast action for error recovery."
  @type git_toast_action :: :pull_and_retry | nil

  @typedoc "Git toast data shown after a remote operation completes."
  @type git_toast :: %{
          required(:message) => String.t(),
          required(:level) => :success | :error,
          required(:action) => git_toast_action(),
          optional(:dismiss_ref) => reference()
        }
end
