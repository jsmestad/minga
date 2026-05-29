defmodule Minga.Frontend.Adapter.GUI.StatusBarEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Agent
  alias Minga.RenderModel.UI.StatusBar.Data
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
  alias Minga.RenderModel.UI.StatusBar.Selection
  alias Minga.RenderModel.UI.StatusBar.Workspace

  @op_gui_status_bar Opcodes.gui_status_bar()
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
  @max_modeline_segments 128

  @spec encode(StatusBar.t(), Caches.t()) :: {binary(), Caches.t()}
  def encode(%StatusBar{} = model, %Caches{} = caches) do
    {encode_command(model), caches}
  end

  @spec encode_command(StatusBar.t()) :: binary()
  def encode_command(%StatusBar{} = model) do
    sections = encode_sections(model)
    IO.iodata_to_binary([<<@op_gui_status_bar, length(sections)::8>> | sections])
  end

  @spec encode_sections(StatusBar.t()) :: [binary()]
  defp encode_sections(%StatusBar{
         content_kind: content_kind,
         data: %Data{} = data,
         workspace: workspace
       }) do
    content_kind_byte = content_kind_byte(content_kind)
    mode_byte = encode_vim_mode(data.mode)
    flags = build_status_flags(data)
    lsp_byte = encode_lsp_status(data.language)
    parser_byte = encode_parser_status(data.language)
    agent_byte = encode_agent_session_status(data.agent.agent_status)
    indent_type_byte = encode_indent_type(data.indent)
    indent_size = Wire.clamp_u8(data.indent.size)
    {selection_mode, selection_size} = encode_selection_info(data.selection)
    {error_count, warning_count, info_count, hint_count} = data.diagnostics.counts
    macro_byte = encode_macro_recording(data.recording)
    {git_added, git_modified, git_deleted} = git_diff_counts(data.git)
    {icon_r, icon_g, icon_b} = Wire.rgb(data.file.icon_color)

    git_branch = :erlang.iolist_to_binary([data.git.branch || ""])
    filetype = :erlang.iolist_to_binary([Atom.to_string(data.file.filetype)])
    icon_bytes = :erlang.iolist_to_binary([data.file.icon])
    filename = :erlang.iolist_to_binary([data.file.name])
    diag_hint = :erlang.iolist_to_binary([data.diagnostics.hint || ""])
    message = :erlang.iolist_to_binary([data.message || ""])
    background_label = :erlang.iolist_to_binary([data.agent.background_label || ""])
    active_tool_name = :erlang.iolist_to_binary([data.agent.active_tool_name || ""])

    sections = [
      Wire.encode_section(@section_identity, <<content_kind_byte::8, mode_byte::8, flags::8>>),
      Wire.encode_section(
        @section_cursor,
        <<data.cursor.line + 1::32, data.cursor.col + 1::32, data.cursor.line_count::32>>
      ),
      Wire.encode_section(
        @section_diagnostics,
        <<error_count::16, warning_count::16, info_count::16, hint_count::16,
          byte_size(diag_hint)::16, diag_hint::binary>>
      ),
      Wire.encode_section(@section_language, <<lsp_byte::8, parser_byte::8>>),
      Wire.encode_section(
        @section_git,
        <<byte_size(git_branch)::8, git_branch::binary, git_added::16, git_modified::16,
          git_deleted::16>>
      ),
      Wire.encode_section(
        @section_file,
        <<byte_size(icon_bytes)::8, icon_bytes::binary, icon_r::8, icon_g::8, icon_b::8,
          byte_size(filename)::16, filename::binary, byte_size(filetype)::8, filetype::binary>>
      ),
      Wire.encode_section(@section_message, <<byte_size(message)::16, message::binary>>),
      Wire.encode_section(@section_recording, <<macro_byte::8>>),
      Wire.encode_section(@section_indent, <<indent_type_byte::8, indent_size::8>>)
    ]

    sections = sections ++ modeline_segment_sections(data.modeline_segments)

    sections =
      sections ++
        [Wire.encode_section(@section_selection, <<selection_mode::8, selection_size::32>>)]

    sections = sections ++ workspace_sections(workspace)

    sections ++
      [agent_section(content_kind, data.agent, agent_byte, background_label, active_tool_name)]
  end

  @spec content_kind_byte(StatusBar.content_kind()) :: 0 | 1
  defp content_kind_byte(:agent), do: 1
  defp content_kind_byte(:buffer), do: 0

  @spec workspace_sections(Workspace.t() | nil) :: [binary()]
  defp workspace_sections(%Workspace{} = workspace) do
    [Wire.encode_section(@section_workspace, encode_status_workspace(workspace))]
  end

  defp workspace_sections(nil), do: []

  @spec encode_status_workspace(Workspace.t()) :: binary()
  defp encode_status_workspace(%Workspace{} = workspace) do
    label_bytes = Wire.utf8_prefix_bytes(workspace.label, 255)
    icon_bytes = Wire.utf8_prefix_bytes(workspace.icon, 255)

    <<workspace.id::16, encode_workspace_kind(workspace.kind)::8,
      encode_agent_session_status(workspace.status)::8,
      encode_workspace_entry_flags(workspace)::16, workspace.draft_count::16,
      workspace.conflict_count::16, workspace.running_background_count::16,
      workspace.attention_count::16, byte_size(label_bytes)::8, label_bytes::binary,
      byte_size(icon_bytes)::8, icon_bytes::binary>>
  end

  @spec agent_section(StatusBar.content_kind(), Agent.t(), non_neg_integer(), binary(), binary()) ::
          binary()
  defp agent_section(:agent, %Agent{} = agent, agent_byte, background_label, active_tool_name) do
    model_name = :erlang.iolist_to_binary([agent.model_name])
    session_status_byte = encode_agent_session_status(agent.session_status)

    Wire.encode_section(
      @section_agent,
      <<byte_size(model_name)::8, model_name::binary, agent.message_count::32,
        session_status_byte::8, agent_byte::8, agent.background_count::16,
        byte_size(background_label)::16, background_label::binary, byte_size(active_tool_name)::8,
        active_tool_name::binary>>
    )
  end

  defp agent_section(:buffer, %Agent{} = agent, agent_byte, background_label, active_tool_name) do
    Wire.encode_section(
      @section_agent,
      <<agent_byte::8, agent.background_count::16, byte_size(background_label)::16,
        background_label::binary, byte_size(active_tool_name)::8, active_tool_name::binary>>
    )
  end

  @spec modeline_segment_sections(Data.modeline_segments()) :: [binary()]
  defp modeline_segment_sections(nil), do: []

  defp modeline_segment_sections(modeline_segments) do
    [Wire.encode_section(@section_modeline_segments, encode_modeline_segments(modeline_segments))]
  end

  @spec encode_modeline_segments(%{left: [tuple()], right: [tuple()]}) :: binary()
  defp encode_modeline_segments(%{left: left, right: right}) do
    {left, right} = capped_modeline_segments(left, right)
    {encoded_left, left_count, remaining} = bounded_modeline_side(left, Wire.max_u16() - 5)
    {encoded_right, right_count, _remaining} = bounded_modeline_side(right, remaining)

    IO.iodata_to_binary([<<2::8, left_count::16, right_count::16>>, encoded_left, encoded_right])
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
    |> Wire.utf8_prefix_bytes(255)
  end

  @spec bounded_modeline_text_and_target(String.t(), String.t(), non_neg_integer()) ::
          {binary(), binary()}
  defp bounded_modeline_text_and_target(text, target, budget) do
    target_bytes = modeline_target_bytes(target, budget)
    text_budget = budget - byte_size(target_bytes)
    text_bytes = Wire.utf8_prefix_bytes(text, min(byte_size(text), text_budget))
    {text_bytes, target_bytes}
  end

  @spec modeline_target_bytes(String.t(), non_neg_integer()) :: binary()
  defp modeline_target_bytes("", _budget), do: ""

  defp modeline_target_bytes(target, budget) do
    target_bytes = :erlang.iolist_to_binary([target])
    if byte_size(target_bytes) <= budget, do: target_bytes, else: ""
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

  @spec encode_indent_type(Indent.t()) :: non_neg_integer()
  defp encode_indent_type(%Indent{type: :tabs}), do: 1
  defp encode_indent_type(%Indent{}), do: 0

  @spec encode_selection_info(Selection.t()) :: {non_neg_integer(), non_neg_integer()}
  defp encode_selection_info(%Selection{mode: :chars, size: count}),
    do: {1, min(count, Wire.max_u32())}

  defp encode_selection_info(%Selection{mode: :lines, size: count}),
    do: {2, min(count, Wire.max_u32())}

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
