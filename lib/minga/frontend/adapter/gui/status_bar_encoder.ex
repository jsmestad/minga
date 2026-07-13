defmodule Minga.Frontend.Adapter.GUI.StatusBarEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Agent
  alias Minga.RenderModel.UI.StatusBar.Data
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
  alias Minga.RenderModel.UI.StatusBar.Operation
  alias Minga.RenderModel.UI.StatusBar.Selection
  alias Minga.RenderModel.UI.StatusBar.Workspace

  @op_gui_status_bar Opcodes.gui_status_bar()
  @command :gui_status_bar
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
  @section_pending_keys 0x0E
  @section_operation 0x0F

  @spec encode(StatusBar.t(), Caches.t()) :: {binary(), Caches.t()}
  def encode(%StatusBar{} = model, %Caches{} = caches), do: {encode_command(model), caches}

  @spec encode_command(StatusBar.t()) :: binary()
  def encode_command(%StatusBar{} = model) do
    sections = encode_sections(model)

    Writer.new(@command)
    |> Writer.uint8(:opcode, @op_gui_status_bar)
    |> Writer.uint8(:section_count, Enum.count(sections))
    |> Writer.append(sections)
    |> Writer.finish()
  end

  @spec encode_sections(StatusBar.t()) :: [binary()]
  defp encode_sections(%StatusBar{
         content_kind: content_kind,
         data: %Data{} = data,
         workspace: workspace,
         operation: operation
       }) do
    {selection_mode, selection_size} = encode_selection_info(data.selection)
    {error_count, warning_count, info_count, hint_count} = data.diagnostics.counts
    {git_added, git_modified, git_deleted} = git_diff_counts(data.git)

    sections = [
      section(
        @section_identity,
        Writer.new(@command)
        |> Writer.uint8(:content_kind, content_kind_byte(content_kind))
        |> Writer.uint8(:mode, encode_vim_mode(data.mode))
        |> Writer.uint8(:flags, build_status_flags(data))
        |> Writer.finish()
      ),
      section(
        @section_cursor,
        Writer.new(@command)
        |> Writer.uint32(:cursor_line, data.cursor.line + 1)
        |> Writer.uint32(:cursor_col, data.cursor.col + 1)
        |> Writer.uint32(:line_count, data.cursor.line_count)
        |> Writer.finish()
      ),
      section(
        @section_diagnostics,
        Writer.new(@command)
        |> Writer.uint16(:diagnostic_error_count, error_count)
        |> Writer.uint16(:diagnostic_warning_count, warning_count)
        |> Writer.uint16(:diagnostic_info_count, info_count)
        |> Writer.uint16(:diagnostic_hint_count, hint_count)
        |> Writer.string16(:diagnostic_hint, data.diagnostics.hint || "")
        |> Writer.finish()
      ),
      section(
        @section_language,
        Writer.new(@command)
        |> Writer.uint8(:lsp_status, encode_lsp_status(data.language))
        |> Writer.uint8(:parser_status, encode_parser_status(data.language))
        |> Writer.finish()
      ),
      section(
        @section_git,
        Writer.new(@command)
        |> Writer.string8(:git_branch, data.git.branch || "")
        |> Writer.uint16(:git_added, git_added)
        |> Writer.uint16(:git_modified, git_modified)
        |> Writer.uint16(:git_deleted, git_deleted)
        |> Writer.finish()
      ),
      section(@section_file, encode_file(data)),
      section(
        @section_message,
        Writer.new(@command) |> Writer.string16(:message, data.message || "") |> Writer.finish()
      ),
      section(
        @section_recording,
        Writer.new(@command)
        |> Writer.uint8(:recording, encode_macro_recording(data.recording))
        |> Writer.finish()
      ),
      section(
        @section_indent,
        Writer.new(@command)
        |> Writer.uint8(:indent_type, encode_indent_type(data.indent))
        |> Writer.uint8(:indent_size, data.indent.size)
        |> Writer.finish()
      )
    ]

    sections = sections ++ modeline_segment_sections(data.modeline_segments)
    sections = sections ++ pending_keys_sections(data.pending_keys)

    sections =
      Enum.concat(sections, [
        section(
          @section_selection,
          Writer.new(@command)
          |> Writer.uint8(:selection_mode, selection_mode)
          |> Writer.uint32(:selection_size, selection_size)
          |> Writer.finish()
        )
      ])

    Enum.concat([
      sections,
      workspace_sections(workspace),
      operation_sections(operation),
      [agent_section(content_kind, data.agent)]
    ])
  end

  @spec encode_file(Data.t()) :: binary()
  defp encode_file(%Data{} = data) do
    Writer.new(@command)
    |> Writer.string8(:file_icon, data.file.icon)
    |> Writer.rgb24(:file_icon_color, data.file.icon_color)
    |> Writer.string16(:file_name, data.file.name)
    |> Writer.string8(:filetype, Atom.to_string(data.file.filetype))
    |> Writer.finish()
  end

  @spec section(non_neg_integer(), iodata()) :: binary()
  defp section(section_id, payload) do
    Writer.new(@command)
    |> Writer.section16(:section_payload, section_id, payload)
    |> Writer.finish()
  end

  @spec content_kind_byte(StatusBar.content_kind()) :: 0 | 1
  defp content_kind_byte(:agent), do: 1
  defp content_kind_byte(:buffer), do: 0

  @spec workspace_sections(Workspace.t() | nil) :: [binary()]
  defp workspace_sections(%Workspace{} = workspace),
    do: [section(@section_workspace, encode_status_workspace(workspace))]

  defp workspace_sections(nil), do: []

  @spec encode_status_workspace(Workspace.t()) :: binary()
  defp encode_status_workspace(%Workspace{} = workspace) do
    Writer.new(@command)
    |> Writer.uint16(:workspace_id, workspace.id)
    |> Writer.uint8(:workspace_kind, encode_workspace_kind(workspace.kind))
    |> Writer.uint8(:workspace_status, encode_agent_session_status(workspace.status))
    |> Writer.uint16(:workspace_flags, encode_workspace_entry_flags(workspace))
    |> Writer.uint16(:workspace_draft_count, workspace.draft_count)
    |> Writer.uint16(:workspace_conflict_count, workspace.conflict_count)
    |> Writer.uint16(:workspace_running_background_count, workspace.running_background_count)
    |> Writer.uint16(:workspace_attention_count, workspace.attention_count)
    |> Writer.string8(:workspace_label, workspace.label)
    |> Writer.string8(:workspace_icon, workspace.icon)
    |> Writer.finish()
  end

  @spec agent_section(StatusBar.content_kind(), Agent.t()) :: binary()
  defp agent_section(:agent, %Agent{} = agent) do
    payload =
      Writer.new(@command)
      |> Writer.string8(:agent_model_name, agent.model_name)
      |> Writer.uint32(:agent_message_count, agent.message_count)
      |> Writer.uint8(:agent_session_status, encode_agent_session_status(agent.session_status))
      |> Writer.uint8(:agent_status, encode_agent_session_status(agent.agent_status))
      |> Writer.uint16(:agent_background_count, agent.background_count)
      |> Writer.string16(:agent_background_label, agent.background_label || "")
      |> Writer.string8(:agent_active_tool_name, agent.active_tool_name || "")
      |> Writer.finish()

    section(@section_agent, payload)
  end

  defp agent_section(:buffer, %Agent{} = agent) do
    payload =
      Writer.new(@command)
      |> Writer.uint8(:agent_status, encode_agent_session_status(agent.agent_status))
      |> Writer.uint16(:agent_background_count, agent.background_count)
      |> Writer.string16(:agent_background_label, agent.background_label || "")
      |> Writer.string8(:agent_active_tool_name, agent.active_tool_name || "")
      |> Writer.finish()

    section(@section_agent, payload)
  end

  @spec operation_sections(Operation.t() | nil) :: [binary()]
  defp operation_sections(nil), do: []

  defp operation_sections(%Operation{} = operation) do
    payload =
      Writer.new(@command)
      |> Writer.uint64(:operation_id, operation.id)
      |> Writer.uint8(:operation_kind, encode_operation_kind(operation.kind))
      |> Writer.uint8(:operation_status, encode_operation_status(operation.status))
      |> Writer.uint8(:operation_flags, operation_flags(operation))
      |> Writer.string16(:operation_message, operation.message)
      |> Writer.uint16(:operation_queue_position, optional_integer(operation.queue_position))
      |> Writer.uint16(:operation_queue_total, optional_integer(operation.queue_total))
      |> Writer.uint32(:operation_progress_current, optional_integer(operation.progress_current))
      |> Writer.uint32(:operation_progress_total, optional_integer(operation.progress_total))
      |> Writer.finish()

    [section(@section_operation, payload)]
  end

  @spec operation_flags(Operation.t()) :: non_neg_integer()
  defp operation_flags(%Operation{} = operation) do
    0
    |> maybe_operation_flag(operation.cancelable?, 0x01)
    |> maybe_operation_flag(is_integer(operation.queue_position), 0x02)
    |> maybe_operation_flag(is_integer(operation.progress_current), 0x04)
  end

  @spec maybe_operation_flag(non_neg_integer(), boolean(), non_neg_integer()) :: non_neg_integer()
  defp maybe_operation_flag(flags, true, bit), do: flags ||| bit
  defp maybe_operation_flag(flags, false, _bit), do: flags

  @spec optional_integer(non_neg_integer() | nil) :: non_neg_integer()
  defp optional_integer(nil), do: 0
  defp optional_integer(value), do: value

  @spec encode_operation_kind(Operation.kind()) :: non_neg_integer()
  defp encode_operation_kind(:external_format), do: 1
  defp encode_operation_kind(:git_stage), do: 2
  defp encode_operation_kind(:git_unstage), do: 3
  defp encode_operation_kind(:git_discard), do: 4
  defp encode_operation_kind(:git_stage_all), do: 5
  defp encode_operation_kind(:git_unstage_all), do: 6
  defp encode_operation_kind(:git_commit), do: 7
  defp encode_operation_kind(:lsp_references), do: 8
  defp encode_operation_kind(:lsp_rename), do: 9

  @spec encode_operation_status(Operation.status()) :: non_neg_integer()
  defp encode_operation_status(:pending), do: 1
  defp encode_operation_status(:queued), do: 2
  defp encode_operation_status(:running), do: 3
  defp encode_operation_status(:success), do: 4
  defp encode_operation_status(:error), do: 5
  defp encode_operation_status(:timeout), do: 6
  defp encode_operation_status(:canceled), do: 7
  defp encode_operation_status(:stale), do: 8

  @spec pending_keys_sections(String.t() | nil) :: [binary()]
  defp pending_keys_sections(pending) when pending in [nil, ""], do: []

  defp pending_keys_sections(pending),
    do: [
      section(
        @section_pending_keys,
        Writer.new(@command) |> Writer.string16(:pending_keys, pending) |> Writer.finish()
      )
    ]

  @spec modeline_segment_sections(Data.modeline_segments()) :: [binary()]
  defp modeline_segment_sections(nil), do: []

  defp modeline_segment_sections(modeline_segments),
    do: [section(@section_modeline_segments, encode_modeline_segments(modeline_segments))]

  @spec encode_modeline_segments(%{left: [tuple()], right: [tuple()]}) :: binary()
  defp encode_modeline_segments(%{left: left, right: right}) do
    Writer.new(@command)
    |> Writer.uint8(:modeline_version, 2)
    |> Writer.uint16(:modeline_left_count, Enum.count(left))
    |> Writer.uint16(:modeline_right_count, Enum.count(right))
    |> Writer.append(Enum.map(left, &encode_modeline_segment/1))
    |> Writer.append(Enum.map(right, &encode_modeline_segment/1))
    |> Writer.finish()
  end

  @spec encode_modeline_segment(tuple()) :: binary()
  defp encode_modeline_segment({name, text, fg, bg, opts, target}) do
    Writer.new(@command)
    |> Writer.string8(:modeline_segment_name, to_string(name))
    |> Writer.rgb24(:modeline_segment_fg, fg)
    |> Writer.rgb24(:modeline_segment_bg, bg)
    |> Writer.uint8(:modeline_segment_attrs, encode_modeline_attrs(opts))
    |> Writer.string16(:modeline_segment_text, text)
    |> Writer.string16(:modeline_segment_target, encode_modeline_target(target))
    |> Writer.finish()
  end

  defp encode_modeline_segment({text, fg, bg, opts, target}),
    do: encode_modeline_segment({:custom, text, fg, bg, opts, target})

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

  @spec encode_indent_type(Indent.t()) :: non_neg_integer()
  defp encode_indent_type(%Indent{type: :tabs}), do: 1
  defp encode_indent_type(%Indent{}), do: 0

  @spec encode_selection_info(Selection.t()) :: {non_neg_integer(), non_neg_integer()}
  defp encode_selection_info(%Selection{mode: :chars, size: count}), do: {1, count}
  defp encode_selection_info(%Selection{mode: :lines, size: count}), do: {2, count}
  defp encode_selection_info(%Selection{}), do: {0, 0}

  @spec encode_lsp_status(Language.t()) :: non_neg_integer()
  defp encode_lsp_status(%Language{lsp_status: :ready}), do: 1
  defp encode_lsp_status(%Language{lsp_status: :initializing}), do: 2
  defp encode_lsp_status(%Language{lsp_status: :starting}), do: 3
  defp encode_lsp_status(%Language{lsp_status: :error}), do: 4
  defp encode_lsp_status(%Language{}), do: 0

  @spec encode_macro_recording({true, String.t()} | false | nil) :: non_neg_integer()
  defp encode_macro_recording({true, <<char::utf8, _::binary>>}) when char >= ?a and char <= ?z,
    do: char - ?a + 1

  defp encode_macro_recording(_), do: 0

  @spec encode_parser_status(Language.t()) :: non_neg_integer()
  defp encode_parser_status(%Language{parser_status: :available}), do: 0
  defp encode_parser_status(%Language{parser_status: :unavailable}), do: 1
  defp encode_parser_status(%Language{parser_status: :restarting}), do: 2
  defp encode_parser_status(%Language{}), do: 0

  @spec git_diff_counts(Git.t()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp git_diff_counts(%Git{diff_summary: {added, modified, deleted}}),
    do: {added, modified, deleted}

  defp git_diff_counts(%Git{}), do: {0, 0, 0}

  @spec build_status_flags(Data.t()) :: non_neg_integer()
  defp build_status_flags(%Data{} = data) do
    has_lsp = if data.language.lsp_status && data.language.lsp_status != :none, do: 1, else: 0
    has_git = if data.git.branch && data.git.branch != "", do: 1, else: 0
    is_dirty = if data.dirty?, do: 1, else: 0
    safe_mode = if data.safe_mode?, do: 1, else: 0
    bor(has_lsp, bor(bsl(has_git, 1), bor(bsl(is_dirty, 2), bsl(safe_mode, 3))))
  end

  @spec encode_agent_session_status(Agent.status() | Workspace.status()) :: non_neg_integer()
  defp encode_agent_session_status(:idle), do: 0
  defp encode_agent_session_status(:thinking), do: 1
  defp encode_agent_session_status(:tool_executing), do: 2
  defp encode_agent_session_status(:error), do: 3
  defp encode_agent_session_status(:plan), do: 4
  defp encode_agent_session_status(_), do: 0

  @spec encode_workspace_kind(Workspace.kind()) :: non_neg_integer()
  defp encode_workspace_kind(:manual), do: 0
  defp encode_workspace_kind(:agent), do: 1

  @spec encode_workspace_entry_flags(Workspace.t()) :: non_neg_integer()
  defp encode_workspace_entry_flags(%Workspace{} = workspace) do
    0
    |> maybe_workspace_flag(workspace.attention?, 0x01)
    |> maybe_workspace_flag(workspace.closeable?, 0x02)
  end

  @spec maybe_workspace_flag(non_neg_integer(), boolean(), non_neg_integer()) :: non_neg_integer()
  defp maybe_workspace_flag(flags, true, bit), do: flags ||| bit
  defp maybe_workspace_flag(flags, false, _bit), do: flags
end
