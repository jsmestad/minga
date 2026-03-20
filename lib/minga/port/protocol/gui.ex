defmodule Minga.Port.Protocol.GUI do
  @moduledoc """
  Binary protocol encoder/decoder for GUI chrome commands (BEAM → Swift/GTK).

  This module handles the structured data protocol for native GUI elements:
  tab bars, file trees, which-key popups, completion menus, breadcrumbs,
  status bars, pickers, agent chat, and theme colors. These are separate
  from the TUI cell-grid rendering commands in `Minga.Port.Protocol`.

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
  """

  import Bitwise

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Devicon
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Filetype
  alias Minga.Theme.Slots

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

  @typedoc "Display type for a gutter row."
  @type display_type :: :normal | :fold_start | :fold_continuation | :wrap_continuation

  @typedoc "A single gutter entry for one visible line."
  @type gutter_entry :: %{
          buf_line: non_neg_integer(),
          display_type: display_type(),
          sign_type: sign_type()
        }

  @typedoc "Gutter data for a single window."
  @type gutter_data :: %{
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
    opcode(1) + content_row(2) + content_col(2) + content_height(2)
    + is_active(1) + cursor_line(4) + line_number_style(1)
    + line_number_width(1) + sign_col_width(1) + line_count(2) + entries...

  Per entry:
    buf_line(4) + display_type(1) + sign_type(1)
  """
  @spec encode_gui_gutter(gutter_data()) :: binary()
  def encode_gui_gutter(%{
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
      Enum.map(entries, fn %{buf_line: bl, display_type: dt, sign_type: st} ->
        <<bl::32, encode_display_type(dt)::8, encode_sign_type(st)::8>>
      end)

    IO.iodata_to_binary([
      <<@op_gui_gutter, row::16, col::16, height::16, active_byte::8, cursor_line::32,
        style_byte::8, ln_width::8, sign_width::8, count::16>>
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
          Minga.Panel.MessageStore.t()
        ) :: {binary(), Minga.Panel.MessageStore.t()}
  def encode_gui_bottom_panel(%{visible: false}, store) do
    {<<@op_gui_bottom_panel, 0>>, store}
  end

  def encode_gui_bottom_panel(%{visible: true} = panel, store) do
    alias Minga.Editor.BottomPanel
    alias Minga.Panel.MessageStore

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

  @spec encode_message_entries([Minga.Panel.MessageStore.Entry.t()]) :: binary()
  defp encode_message_entries(entries) do
    alias Minga.Panel.MessageStore

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
  @spec encode_gui_theme(Minga.Theme.t()) :: binary()
  def encode_gui_theme(%Minga.Theme{} = theme) do
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
  has_attention, agent_status in upper bits), tab id, Nerd Font icon,
  and display label.
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

    icon = tab_icon(tab)
    icon_bytes = :erlang.iolist_to_binary([icon])
    label_bytes = :erlang.iolist_to_binary([tab.label])

    <<flags::8, tab.id::32, byte_size(icon_bytes)::8, icon_bytes::binary,
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

  # ── File tree ──

  @doc """
  Encodes a gui_file_tree command with the visible file tree entries.

  Sends: selected_index, tree_width, entry_count, root_len, root, then per entry:
  path_hash, flags (is_dir, is_expanded), depth, git_status, icon, name, rel_path.
  """
  @spec encode_gui_file_tree(Minga.FileTree.t() | nil) :: binary()
  def encode_gui_file_tree(nil), do: <<@op_gui_file_tree, 0::16, 0::16, 0::16, 0::16>>

  def encode_gui_file_tree(%Minga.FileTree{} = tree) do
    entries = Minga.FileTree.visible_entries(tree)
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

  @spec encode_file_tree_entry(Minga.FileTree.entry(), Minga.FileTree.t(), boolean()) :: binary()
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

  @spec file_tree_icon(Minga.FileTree.entry()) :: String.t()
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
  @spec encode_gui_completion(Minga.Completion.t() | nil, non_neg_integer(), non_neg_integer()) ::
          binary()
  def encode_gui_completion(nil, _row, _col), do: <<@op_gui_completion, 0::8>>

  def encode_gui_completion(%Minga.Completion{filtered: []}, _row, _col) do
    <<@op_gui_completion, 0::8>>
  end

  def encode_gui_completion(%Minga.Completion{} = comp, cursor_row, cursor_col) do
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
    bindings = Minga.WhichKey.bindings_from_node(node)
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
    flags = build_buffer_status_flags(d)

    git_branch = :erlang.iolist_to_binary([d.git_branch || ""])
    filetype = :erlang.iolist_to_binary([Atom.to_string(d.filetype || :text)])
    {error_count, warning_count} = diagnostic_counts_from_buffer_data(d)

    # cursor_line/cursor_col are 0-indexed from BufferServer; encode as 1-indexed for the GUI
    <<@op_gui_status_bar, 0::8, mode_byte::8, d.cursor_line + 1::32, d.cursor_col + 1::32,
      d.line_count::32, flags::8, lsp_byte::8, byte_size(git_branch)::8, git_branch::binary,
      0::16, byte_size(filetype)::8, filetype::binary, error_count::16, warning_count::16>>
  end

  def encode_gui_status_bar({:agent, d}) do
    mode_byte = encode_vim_mode(d.mode)
    model_name = :erlang.iolist_to_binary([d.model_name || "Agent"])
    session_status_byte = encode_agent_session_status(d.session_status)

    # Shared header fields are all zeros (not meaningful for agent windows).
    # message_count and session_status are explicit fields — no slot reuse.
    <<@op_gui_status_bar, 1::8, mode_byte::8, 0::32, 0::32, 0::32, 0::8, 0::8, 0::8, 0::16, 0::8,
      0::16, 0::16, byte_size(model_name)::8, model_name::binary, d.message_count::32,
      session_status_byte::8>>
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

  @spec diagnostic_counts_from_buffer_data(map()) :: {non_neg_integer(), non_neg_integer()}
  defp diagnostic_counts_from_buffer_data(d) do
    case d.diagnostic_counts do
      {errors, warnings, _info, _hints} -> {errors, warnings}
      _ -> {0, 0}
    end
  end

  @spec build_buffer_status_flags(map()) :: non_neg_integer()
  defp build_buffer_status_flags(d) do
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

  @spec encode_gui_picker(Minga.Picker.t() | nil, boolean(), action_menu_state()) :: binary()
  def encode_gui_picker(picker, has_preview \\ false, action_menu \\ nil)
  def encode_gui_picker(nil, _has_preview, _action_menu), do: <<@op_gui_picker, 0::8>>

  def encode_gui_picker(%Minga.Picker{} = picker, has_preview, action_menu) do
    items = Enum.take(picker.filtered, picker.max_visible)
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

  @spec encode_picker_item_flags(Minga.Picker.Item.t(), Minga.Picker.t()) :: non_neg_integer()
  defp encode_picker_item_flags(item, picker) do
    two_line = if item.two_line, do: 1, else: 0
    marked = if Minga.Picker.marked?(picker, item), do: 1, else: 0
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

  @doc "Encodes a gui_agent_chat command with conversation messages."
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

    msg_binaries =
      messages
      |> Enum.take(100)
      |> Enum.map(&encode_chat_message/1)

    IO.iodata_to_binary([
      @op_gui_agent_chat,
      <<1::8, status_byte::8, byte_size(model_bytes)::16, model_bytes::binary,
        byte_size(prompt_bytes)::16, prompt_bytes::binary>>,
      pending_bytes,
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

  @spec encode_chat_message(gui_chat_message()) :: binary()
  defp encode_chat_message({:user, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:user, text, _attachments}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:assistant, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x02::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  # Styled assistant message: opcode 0x07, line_count::16, then per line:
  # run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8
  defp encode_chat_message({:styled_assistant, styled_lines}) do
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

  defp encode_chat_message({:thinking, text, collapsed}) do
    collapsed_byte = if collapsed, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x03::8, collapsed_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:tool_call, tc}) do
    name_bytes = :erlang.iolist_to_binary([tc.name])
    result_bytes = :erlang.iolist_to_binary([tc.result || ""])

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
      byte_size(name_bytes)::16, name_bytes::binary, byte_size(result_bytes)::32,
      result_bytes::binary>>
  end

  defp encode_chat_message({:system, text, level}) do
    level_byte = if level == :error, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x05::8, level_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:usage, u}) do
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

  def decode_gui_action(_, _), do: :error
end
