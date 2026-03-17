defmodule Minga.Port.Protocol.GUI do
  @moduledoc """
  Binary protocol encoder/decoder for GUI chrome commands (BEAM → Swift/GTK).

  This module handles the structured data protocol for native GUI elements:
  tab bars, file trees, which-key popups, completion menus, breadcrumbs,
  status bars, pickers, agent chat, and theme colors. These are separate
  from the TUI cell-grid rendering commands in `Minga.Port.Protocol`.

  ## GUI Chrome Commands (BEAM → Frontend)

  | Opcode | Name          | Description                    |
  |--------|---------------|--------------------------------|
  | 0x1C   | gui_tab_bar   | Tab bar with tab entries       |
  | 0x1D   | gui_which_key | Which-key popup bindings       |
  | 0x1E   | gui_completion| Completion popup items         |
  | 0x1F   | gui_theme     | Theme color slots              |
  | 0x70   | gui_file_tree | File tree entries              |
  | 0x71   | gui_breadcrumb| Path breadcrumb segments       |
  | 0x72   | gui_status_bar| Status bar data                |
  | 0x73   | gui_picker    | Fuzzy picker items             |
  | 0x74   | gui_agent_chat| Agent conversation view        |

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
  """

  import Bitwise

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Devicon
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Filetype
  alias Minga.Theme.Slots

  # ── GUI chrome opcodes (BEAM → Frontend) ──

  @op_gui_file_tree 0x70
  @op_gui_tab_bar 0x1C
  @op_gui_which_key 0x1D
  @op_gui_completion 0x1E
  @op_gui_theme 0x1F
  @op_gui_breadcrumb 0x71
  @op_gui_status_bar 0x72
  @op_gui_picker 0x73
  @op_gui_agent_chat 0x74

  # ── GUI action sub-opcodes (Frontend → BEAM) ──

  @gui_action_select_tab 0x01
  @gui_action_close_tab 0x02
  @gui_action_file_tree_click 0x03
  @gui_action_file_tree_toggle 0x04
  @gui_action_completion_select 0x05
  @gui_action_breadcrumb_click 0x06
  @gui_action_toggle_panel 0x07
  @gui_action_new_tab 0x08

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

  # ═══════════════════════════════════════════════════════════════════════════
  # Encoding (BEAM → Frontend)
  # ═══════════════════════════════════════════════════════════════════════════

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

  Sends: selected_index, tree_width, entry_count, then per entry:
  flags (is_dir, is_expanded), depth, git_status, icon, name.
  """
  @spec encode_gui_file_tree(Minga.FileTree.t() | nil) :: binary()
  def encode_gui_file_tree(nil), do: <<@op_gui_file_tree, 0::16, 0::16, 0::16>>

  def encode_gui_file_tree(%Minga.FileTree{} = tree) do
    entries = Minga.FileTree.visible_entries(tree)
    count = length(entries)

    entry_binaries =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        encode_file_tree_entry(entry, tree, index == tree.cursor)
      end)

    IO.iodata_to_binary([
      @op_gui_file_tree,
      <<tree.cursor::16, tree.width::16, count::16>>
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

    <<flags::8, entry.depth::8, git_status::8, byte_size(icon_bytes)::8, icon_bytes::binary,
      byte_size(name_bytes)::16, name_bytes::binary>>
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

  @doc "Encodes a gui_status_bar command."
  @spec encode_gui_status_bar(map()) :: binary()
  def encode_gui_status_bar(data) do
    mode_byte = encode_vim_mode(data.mode)
    lsp_byte = encode_lsp_status(data[:lsp_status])
    flags = build_status_flags(data)

    git_branch = :erlang.iolist_to_binary([data[:git_branch] || ""])
    message = :erlang.iolist_to_binary([data[:status_msg] || ""])
    filetype = :erlang.iolist_to_binary([Atom.to_string(data[:filetype] || :text)])

    <<@op_gui_status_bar, mode_byte::8, data.cursor_line::32, data.cursor_col::32,
      data.line_count::32, flags::8, lsp_byte::8, byte_size(git_branch)::8, git_branch::binary,
      byte_size(message)::16, message::binary, byte_size(filetype)::8, filetype::binary>>
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

  @spec build_status_flags(map()) :: non_neg_integer()
  defp build_status_flags(data) do
    has_lsp = if data[:lsp_status] && data[:lsp_status] != :none, do: 1, else: 0
    has_git = if data[:git_branch], do: 1, else: 0
    is_dirty = if data[:dirty_marker] && data[:dirty_marker] != "", do: 1, else: 0
    bor(has_lsp, bor(bsl(has_git, 1), bsl(is_dirty, 2)))
  end

  # ── Picker ──

  @doc "Encodes a gui_picker command."
  @spec encode_gui_picker(Minga.Picker.t() | nil) :: binary()
  def encode_gui_picker(nil), do: <<@op_gui_picker, 0::8>>

  def encode_gui_picker(%Minga.Picker{} = picker) do
    items = Enum.take(picker.filtered, picker.max_visible)
    title_bytes = :erlang.iolist_to_binary([picker.title])
    query_bytes = :erlang.iolist_to_binary([picker.query])

    entries =
      Enum.map(items, fn item ->
        label_bytes = :erlang.iolist_to_binary([item.label])
        desc_bytes = :erlang.iolist_to_binary([item.description || ""])
        icon_color = item.icon_color || 0

        <<icon_color::24, byte_size(label_bytes)::16, label_bytes::binary,
          byte_size(desc_bytes)::16, desc_bytes::binary>>
      end)

    IO.iodata_to_binary([
      @op_gui_picker,
      <<1::8, picker.selected::16, byte_size(title_bytes)::16, title_bytes::binary,
        byte_size(query_bytes)::16, query_bytes::binary, length(items)::16>>
      | entries
    ])
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

  @spec encode_chat_message(Minga.Agent.Message.t()) :: binary()
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
  def decode_gui_action(_, _), do: :error
end
