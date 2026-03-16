defmodule Minga.Agent.ChatDecorations do
  @moduledoc """
  Produces decorations for the `*Agent*` buffer based on chat messages.

  Translates the agent session's message list into highlight ranges,
  block decorations, virtual text, and fold regions on the `*Agent*`
  buffer. The buffer rendering pipeline handles the actual drawing.

  By using decorations instead of a custom renderer, the chat gets visual
  mode selection, yank, mouse drag, and search for free via the standard
  buffer pipeline.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Server, as: BufferServer

  @typedoc "Line offset: {message_index, start_line, line_count}"
  @type line_offset :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Applies decorations to the `*Agent*` buffer based on the current messages.

  Called after `BufferSync.sync/2` writes the markdown content. Uses
  pre-computed `line_offsets` from BufferSync to place decorations at
  correct buffer positions without re-deriving the markdown format.
  """
  @spec apply(pid(), [term()], [line_offset()], Minga.Theme.Agent.t(), keyword()) :: :ok
  def apply(buf, messages, line_offsets, agent_theme, opts \\ []) do
    BufferServer.batch_decorations(buf, fn decs ->
      decs
      |> Decorations.clear()
      |> build_decorations(messages, line_offsets, agent_theme, opts)
    end)

    :ok
  end

  @doc "Builds decorations from messages and line offsets. Captures current spinner frame at call time."
  @spec build_decorations(
          Decorations.t(),
          [term()],
          [line_offset()],
          Minga.Theme.Agent.t(),
          keyword()
        ) :: Decorations.t()
  def build_decorations(decs, messages, line_offsets, theme, opts \\ []) do
    streaming = Keyword.get(opts, :streaming, false)
    pending_approval = Keyword.get(opts, :pending_approval)
    offset_map = Map.new(line_offsets, fn {idx, start, count} -> {idx, {start, count}} end)

    last_idx = length(messages) - 1

    messages
    |> Enum.with_index()
    |> Enum.reduce(decs, fn {msg, idx}, d ->
      case Map.get(offset_map, idx) do
        {start_line, line_count} ->
          log_decoration(msg, idx, start_line, line_count)
          is_last = idx == last_idx

          apply_message_decorations(
            d,
            msg,
            start_line,
            line_count,
            theme,
            streaming and is_last,
            pending_approval
          )

        nil ->
          Minga.Log.warning(:agent, "[chat_decs] no offset for msg idx=#{idx}")
          d
      end
    end)
  end

  defp log_decoration(msg, idx, start_line, line_count) do
    msg_type =
      case msg do
        {t, _} -> t
        {t, _, _} -> t
        _ -> :unknown
      end

    Minga.Log.debug(
      :agent,
      "[chat_decs] #{msg_type} idx=#{idx} start=#{start_line} lines=#{line_count}"
    )
  end

  # ── Per-message decoration builders ──────────────────────────────────────

  defp apply_message_decorations(
         decs,
         {:user, _text, _attachments},
         line,
         line_count,
         theme,
         _streaming,
         _pending_approval
       ) do
    apply_user_decorations(decs, line, line_count, theme)
  end

  defp apply_message_decorations(
         decs,
         {:user, _text},
         line,
         line_count,
         theme,
         _streaming,
         _pending_approval
       ) do
    apply_user_decorations(decs, line, line_count, theme)
  end

  defp apply_message_decorations(
         decs,
         {:assistant, text},
         line,
         line_count,
         theme,
         streaming,
         _pending_approval
       ) do
    {_id, decs} =
      Decorations.add_block_decoration(decs, line,
        placement: :above,
        render: fn _w ->
          [{"▎ Agent", [fg: theme.assistant_border, bold: true, bg: theme.header_bg]}]
        end,
        priority: 10
      )

    # Spinner as EOL virtual text when streaming (updates on each sync call)
    decs =
      if streaming do
        {_id, decs} =
          Decorations.add_virtual_text(decs, {line, 0},
            segments: [{spinner_frame(), [fg: theme.status_thinking, italic: true]}],
            placement: :eol
          )

        decs
      else
        decs
      end

    decs = add_border_virtual_text(decs, line, line_count, theme.assistant_border)

    # Code block background highlights (lines between ``` fences)
    decs = add_code_block_highlights(decs, text, line, theme.code_bg)

    # Dim markdown delimiters (**, *, `, #, ```, [...](...))
    add_markdown_delimiter_dims(decs, text, line, theme)
  end

  defp apply_message_decorations(
         decs,
         {:thinking, _text, collapsed},
         line,
         line_count,
         theme,
         _streaming,
         _pending_approval
       ) do
    # Header
    {_id, decs} =
      Decorations.add_block_decoration(decs, line,
        placement: :above,
        render: fn _w ->
          [{"┌─ 💭 Thinking", [fg: theme.thinking_fg, italic: true]}]
        end,
        priority: 5
      )

    # Fold collapsed thinking blocks
    decs =
      if collapsed do
        {_id, decs} =
          Decorations.add_fold_region(decs, line, line + line_count - 1,
            closed: true,
            placeholder: fn _s, _e, _w ->
              [{"└─ 💭 Thinking (#{line_count} lines)...", [fg: theme.thinking_fg, italic: true]}]
            end
          )

        decs
      else
        decs
      end

    # Dim thinking text
    {_id, decs} =
      Decorations.add_highlight(decs, {line, 0}, {line + line_count, 0},
        style: [fg: theme.thinking_fg],
        priority: 5,
        group: :chat_thinking
      )

    # Left border (│) and bottom border (└─)
    decs = add_tool_border_virtual_text(decs, line, line_count, theme.thinking_fg)
    last_line = line + line_count - 1

    {_id, decs} =
      Decorations.add_block_decoration(decs, last_line,
        placement: :below,
        render: fn _w ->
          [{"└─", [fg: theme.thinking_fg]}]
        end,
        priority: 5
      )

    decs
  end

  defp apply_message_decorations(
         decs,
         {:tool_call, tc},
         line,
         line_count,
         theme,
         _streaming,
         pending_approval
       ) do
    awaiting_approval = tool_awaiting_approval?(tc, pending_approval)
    apply_tool_call_decorations(decs, tc, line, line_count, theme, awaiting_approval)
  end

  defp apply_message_decorations(
         decs,
         {:usage, _usage},
         line,
         line_count,
         theme,
         _streaming,
         _pending_approval
       ) do
    # Dim the usage stats line
    {_id, decs} =
      Decorations.add_highlight(decs, {line, 0}, {line + line_count, 0},
        style: [fg: theme.usage_fg],
        priority: 10,
        group: :chat_usage
      )

    decs
  end

  defp apply_message_decorations(
         decs,
         {:system, _text, level},
         line,
         line_count,
         theme,
         _streaming,
         _pending_approval
       ) do
    label_fg = if level == :error, do: theme.status_error, else: theme.system_fg

    {_id, decs} =
      Decorations.add_block_decoration(decs, line,
        placement: :above,
        render: fn _w ->
          [{"System", [fg: label_fg, bold: true, bg: theme.header_bg]}]
        end,
        priority: 5
      )

    # Dim the system message text
    {_id, decs} =
      Decorations.add_highlight(decs, {line, 0}, {line + line_count, 0},
        style: [fg: theme.system_fg],
        priority: 5,
        group: :chat_system
      )

    decs
  end

  defp apply_message_decorations(
         decs,
         _other,
         _line,
         _line_count,
         _theme,
         _streaming,
         _pending_approval
       ),
       do: decs

  # ── Tool call decorations ────────────────────────────────────────────────────

  @spec tool_awaiting_approval?(map(), map() | nil) :: boolean()
  defp tool_awaiting_approval?(_tc, nil), do: false

  defp tool_awaiting_approval?(tc, approval) when is_map(approval) do
    Map.get(approval, :tool_call_id) == tc.id
  end

  @spec apply_tool_call_decorations(
          Decorations.t(),
          map(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.Theme.Agent.t(),
          boolean()
        ) :: Decorations.t()
  defp apply_tool_call_decorations(decs, tc, line, line_count, theme, awaiting_approval) do
    {status_icon, status_fg} = tool_status_display(tc, theme, awaiting_approval)

    has_result = tc.result != ""

    # Build header text with timing and command info
    duration_text = format_tool_duration(tc)
    command_text = format_tool_command(tc)
    header_text = "┌─ #{status_icon} #{tc.name}#{duration_text}#{command_text}"

    # Block decoration: tool header (with approval prompt when awaiting)
    {_id, decs} =
      Decorations.add_block_decoration(decs, line,
        placement: :above,
        render: tool_header_render(header_text, status_fg, theme, awaiting_approval),
        priority: 5
      )

    # Fold region for tool output (collapsible with za)
    fold_placeholder = "└─ #{status_icon} #{tc.name} (#{line_count} lines)"

    decs =
      if has_result and tc.status != :running do
        {_id, decs} =
          Decorations.add_fold_region(decs, line, line + line_count - 1,
            closed: tc.collapsed,
            placeholder: fn _s, _e, _w ->
              [{fold_placeholder, [fg: status_fg, italic: true]}]
            end
          )

        decs
      else
        decs
      end

    # Dim tool output text
    {_id, decs} =
      Decorations.add_highlight(decs, {line, 0}, {line + line_count, 0},
        style: [fg: theme.text_fg],
        priority: -10,
        group: :chat_tool
      )

    # Left border (│) on each content line
    decs = add_tool_border_virtual_text(decs, line, line_count, theme.tool_border)

    # Bottom border
    last_line = line + line_count - 1

    {_id, decs} =
      Decorations.add_block_decoration(decs, last_line,
        placement: :below,
        render: fn _w -> [{"└─", [fg: status_fg]}] end,
        priority: 5
      )

    decs
  end

  @spec tool_status_display(map(), Minga.Theme.Agent.t(), boolean()) ::
          {String.t(), non_neg_integer()}
  defp tool_status_display(_tc, theme, true = _awaiting) do
    {"?", theme.status_thinking}
  end

  defp tool_status_display(tc, theme, false) do
    case tc.status do
      :running -> {"⟳", theme.status_tool}
      :complete -> {"✓", theme.tool_header}
      :error -> {"✗", theme.status_error}
    end
  end

  @spec tool_header_render(String.t(), non_neg_integer(), Minga.Theme.Agent.t(), boolean()) ::
          (non_neg_integer() -> [{String.t(), keyword()}])
  defp tool_header_render(header_text, status_fg, theme, true = _awaiting) do
    fn _w ->
      [
        {header_text, [fg: status_fg, bold: true]},
        {" ", []},
        {"Approve? ", [fg: status_fg, bold: true]},
        {"[y]", [fg: theme.tool_header, bold: true]},
        {"es ", [fg: status_fg]},
        {"[n]", [fg: theme.status_error, bold: true]},
        {"o ", [fg: status_fg]},
        {"[Y]", [fg: theme.tool_header, bold: true]},
        {"es-all", [fg: status_fg]}
      ]
    end
  end

  defp tool_header_render(header_text, status_fg, _theme, false) do
    fn _w ->
      [{header_text, [fg: status_fg, bold: true]}]
    end
  end

  # ── Markdown delimiter dimming ──────────────────────────────────────────────

  # Scans assistant message text for markdown delimiter characters and adds
  # highlight ranges to dim them (near-background color). This makes `**bold**`
  # show styled bold text with barely-visible asterisks, `# Heading` show the
  # heading color with a dimmed hash, etc.
  #
  # Uses simple pattern matching rather than tree-sitter AST queries because
  # ChatDecorations runs outside the parser process. This handles well-formed
  # LLM output correctly. Edge cases in hand-written markdown are acceptable
  # at this stage.
  #
  # All column positions are grapheme-based (not byte offsets). Regex matches
  # return byte offsets, so we convert via `byte_offset_to_grapheme/2`.
  @spec add_markdown_delimiter_dims(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          Minga.Theme.Agent.t()
        ) :: Decorations.t()
  defp add_markdown_delimiter_dims(decs, md_text, base_line, theme) do
    md_text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce({decs, false}, fn {line_text, idx}, {d, in_code_block} ->
      dim_markdown_line(d, line_text, base_line + idx, in_code_block, theme)
    end)
    |> elem(0)
  end

  # Processes a single line for delimiter dimming, tracking fenced code block state.
  @spec dim_markdown_line(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          boolean(),
          Minga.Theme.Agent.t()
        ) ::
          {Decorations.t(), boolean()}
  defp dim_markdown_line(decs, line_text, buf_line, in_code_block, theme) do
    trimmed = String.trim_leading(line_text)

    if String.starts_with?(trimmed, "```") do
      dim_fence_line(decs, line_text, buf_line, trimmed, in_code_block, theme)
    else
      dim_non_fence_line(decs, line_text, buf_line, in_code_block, theme)
    end
  end

  defp dim_fence_line(decs, line_text, buf_line, trimmed, in_code_block, theme) do
    fence_start = String.length(line_text) - String.length(trimmed)

    {_id, decs} =
      Decorations.add_highlight(
        decs,
        {buf_line, fence_start},
        {buf_line, fence_start + String.length(trimmed)},
        style: [fg: theme.delimiter_dim],
        priority: 15,
        group: :chat_md_delimiters
      )

    {decs, not in_code_block}
  end

  defp dim_non_fence_line(decs, _line_text, _buf_line, true = _in_code_block, _theme) do
    {decs, true}
  end

  defp dim_non_fence_line(decs, line_text, buf_line, false = _in_code_block, theme) do
    {dim_line_delimiters(decs, line_text, buf_line, theme), false}
  end

  # Dims markdown delimiters on a single line (outside code blocks).
  @spec dim_line_delimiters(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          Minga.Theme.Agent.t()
        ) :: Decorations.t()
  defp dim_line_delimiters(decs, line_text, buf_line, theme) do
    trimmed = String.trim_leading(line_text)
    indent = String.length(line_text) - String.length(trimmed)

    decs
    |> dim_heading_markers(trimmed, buf_line, indent, theme)
    |> dim_bold_delimiters(line_text, buf_line, theme)
    |> dim_italic_delimiters(line_text, buf_line, theme)
    |> dim_inline_code_delimiters(line_text, buf_line, theme)
    |> dim_link_delimiters(line_text, buf_line, theme)
    |> dim_list_markers(trimmed, buf_line, indent, theme)
  end

  # Converts a byte offset within a string to a grapheme column.
  # Regex.scan with return: :index gives byte offsets; decorations need grapheme columns.
  @spec byte_offset_to_grapheme(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_to_grapheme(text, byte_offset) do
    # Take the first byte_offset bytes, then count graphemes in that prefix
    prefix = binary_part(text, 0, byte_offset)
    String.length(prefix)
  end

  # Dims `# `, `## `, `### ` heading markers
  @spec dim_heading_markers(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.Theme.Agent.t()
        ) ::
          Decorations.t()
  defp dim_heading_markers(decs, trimmed, buf_line, indent, theme) do
    case Regex.run(~r/^(\#{1,6})\s/, trimmed) do
      [_match, hashes] ->
        hash_len = String.length(hashes)

        {_id, decs} =
          Decorations.add_highlight(
            decs,
            {buf_line, indent},
            {buf_line, indent + hash_len + 1},
            style: [fg: theme.delimiter_dim],
            priority: 15,
            group: :chat_md_delimiters
          )

        decs

      _ ->
        decs
    end
  end

  # Dims `**` bold delimiters
  @spec dim_bold_delimiters(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          Minga.Theme.Agent.t()
        ) :: Decorations.t()
  defp dim_bold_delimiters(decs, line_text, buf_line, theme) do
    Regex.scan(~r/\*\*/, line_text, return: :index)
    |> List.flatten()
    |> Enum.reduce(decs, fn {byte_start, byte_len}, d ->
      col = byte_offset_to_grapheme(line_text, byte_start)
      grapheme_len = byte_offset_to_grapheme(line_text, byte_start + byte_len) - col

      {_id, d} =
        Decorations.add_highlight(
          d,
          {buf_line, col},
          {buf_line, col + grapheme_len},
          style: [fg: theme.delimiter_dim],
          priority: 15,
          group: :chat_md_delimiters
        )

      d
    end)
  end

  # Dims `*` italic delimiters (but not `**` which is handled separately)
  @spec dim_italic_delimiters(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          Minga.Theme.Agent.t()
        ) :: Decorations.t()
  defp dim_italic_delimiters(decs, line_text, buf_line, theme) do
    # Match single * not preceded or followed by another *
    Regex.scan(~r/(?<!\*)\*(?!\*)/, line_text, return: :index)
    |> List.flatten()
    |> Enum.reduce(decs, fn {byte_start, byte_len}, d ->
      col = byte_offset_to_grapheme(line_text, byte_start)
      grapheme_len = byte_offset_to_grapheme(line_text, byte_start + byte_len) - col

      {_id, d} =
        Decorations.add_highlight(
          d,
          {buf_line, col},
          {buf_line, col + grapheme_len},
          style: [fg: theme.delimiter_dim],
          priority: 15,
          group: :chat_md_delimiters
        )

      d
    end)
  end

  # Dims `` ` `` inline code delimiters
  @spec dim_inline_code_delimiters(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          Minga.Theme.Agent.t()
        ) ::
          Decorations.t()
  defp dim_inline_code_delimiters(decs, line_text, buf_line, theme) do
    # Match backtick pairs (single or double)
    Regex.scan(~r/(`{1,2})(.+?)\1/, line_text, return: :index)
    |> Enum.reduce(decs, fn matches, d ->
      case matches do
        [{full_byte_start, full_byte_len}, {delim_byte_start, delim_byte_len} | _] ->
          open_col = byte_offset_to_grapheme(line_text, delim_byte_start)
          open_end = byte_offset_to_grapheme(line_text, delim_byte_start + delim_byte_len)

          # Dim opening delimiter
          {_id, d} =
            Decorations.add_highlight(
              d,
              {buf_line, open_col},
              {buf_line, open_end},
              style: [fg: theme.delimiter_dim],
              priority: 15,
              group: :chat_md_delimiters
            )

          # Dim closing delimiter
          close_byte_start = full_byte_start + full_byte_len - delim_byte_len
          close_col = byte_offset_to_grapheme(line_text, close_byte_start)
          close_end = byte_offset_to_grapheme(line_text, close_byte_start + delim_byte_len)

          {_id, d} =
            Decorations.add_highlight(
              d,
              {buf_line, close_col},
              {buf_line, close_end},
              style: [fg: theme.delimiter_dim],
              priority: 15,
              group: :chat_md_delimiters
            )

          d

        _ ->
          d
      end
    end)
  end

  # Dims link syntax: `[text](url)` - dims brackets and URL, highlights link text
  @spec dim_link_delimiters(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          Minga.Theme.Agent.t()
        ) :: Decorations.t()
  defp dim_link_delimiters(decs, line_text, buf_line, theme) do
    Regex.scan(~r/\[([^\]]+)\]\(([^)]+)\)/, line_text, return: :index)
    |> Enum.reduce(decs, fn matches, d ->
      case matches do
        [
          {full_byte_start, full_byte_len},
          {text_byte_start, text_byte_len},
          {url_byte_start, url_byte_len}
        ] ->
          full_col = byte_offset_to_grapheme(line_text, full_byte_start)
          text_col = byte_offset_to_grapheme(line_text, text_byte_start)
          text_end = byte_offset_to_grapheme(line_text, text_byte_start + text_byte_len)
          url_col = byte_offset_to_grapheme(line_text, url_byte_start)
          url_end = byte_offset_to_grapheme(line_text, url_byte_start + url_byte_len)
          full_end = byte_offset_to_grapheme(line_text, full_byte_start + full_byte_len)

          # Dim opening bracket [
          {_id, d} =
            Decorations.add_highlight(
              d,
              {buf_line, full_col},
              {buf_line, full_col + 1},
              style: [fg: theme.delimiter_dim],
              priority: 15,
              group: :chat_md_delimiters
            )

          # Highlight link text with link_fg
          {_id, d} =
            Decorations.add_highlight(
              d,
              {buf_line, text_col},
              {buf_line, text_end},
              style: [fg: theme.link_fg],
              priority: 15,
              group: :chat_md_delimiters
            )

          # Dim ]( between text and URL
          {_id, d} =
            Decorations.add_highlight(
              d,
              {buf_line, text_end},
              {buf_line, url_col},
              style: [fg: theme.delimiter_dim],
              priority: 15,
              group: :chat_md_delimiters
            )

          # Dim the URL itself
          {_id, d} =
            Decorations.add_highlight(
              d,
              {buf_line, url_col},
              {buf_line, url_end},
              style: [fg: theme.delimiter_dim],
              priority: 15,
              group: :chat_md_delimiters
            )

          # Dim closing )
          {_id, d} =
            Decorations.add_highlight(
              d,
              {buf_line, full_end - 1},
              {buf_line, full_end},
              style: [fg: theme.delimiter_dim],
              priority: 15,
              group: :chat_md_delimiters
            )

          d

        _ ->
          d
      end
    end)
  end

  # Dims list markers: `- `, `* ` (unordered) and `1. ` (ordered)
  @spec dim_list_markers(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.Theme.Agent.t()
        ) ::
          Decorations.t()
  defp dim_list_markers(decs, trimmed, buf_line, indent, theme) do
    case Regex.run(~r/^([-*+]|\d+\.)\s/, trimmed) do
      [_match, marker] ->
        marker_len = String.length(marker)

        {_id, decs} =
          Decorations.add_highlight(
            decs,
            {buf_line, indent},
            {buf_line, indent + marker_len},
            style: [fg: theme.delimiter_dim],
            priority: 15,
            group: :chat_md_delimiters
          )

        decs

      _ ->
        decs
    end
  end

  # Detects fenced code blocks (``` ... ```) in markdown text and adds
  # background highlight ranges for the block region.
  @spec add_code_block_highlights(
          Decorations.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          Decorations.t()
  defp add_code_block_highlights(decs, md_text, base_line, code_bg) do
    md_text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce({decs, false, 0}, fn {line_text, idx}, {d, in_block, block_start} ->
      handle_fence_line(line_text, idx, d, in_block, block_start, base_line, code_bg)
    end)
    |> elem(0)
  end

  defp handle_fence_line(line_text, idx, decs, in_block, block_start, base_line, code_bg) do
    if String.starts_with?(String.trim_leading(line_text), "```") do
      toggle_code_block(decs, in_block, block_start, idx, base_line, code_bg)
    else
      {decs, in_block, block_start}
    end
  end

  defp toggle_code_block(decs, true, block_start, idx, base_line, code_bg) do
    {_id, decs} =
      Decorations.add_highlight(decs, {base_line + block_start, 0}, {base_line + idx + 1, 0},
        style: [bg: code_bg],
        priority: -18,
        group: :chat_code_bg
      )

    {decs, false, 0}
  end

  defp toggle_code_block(decs, false, _block_start, idx, _base_line, _code_bg) do
    {decs, true, idx}
  end

  # Adds a colored border highlight on the first 2 columns of each content line.
  # This creates the vertical "▎" border effect on the left edge of each message.
  # Adds an inline virtual text "│ " at column 0 of each tool output line.
  @spec add_tool_border_virtual_text(
          Decorations.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          Decorations.t()
  defp add_tool_border_virtual_text(decs, start_line, line_count, border_fg) do
    Enum.reduce(0..(line_count - 1), decs, fn offset, d ->
      line = start_line + offset

      {_id, d} =
        Decorations.add_virtual_text(d, {line, 0},
          segments: [{"│ ", [fg: border_fg]}],
          placement: :inline,
          priority: 10
        )

      d
    end)
  end

  # Adds an inline virtual text "▎ " at column 0 of each content line.
  # The border character lives in the decoration layer, not the buffer text,
  # so yank/search/clipboard stay clean.
  @spec add_border_virtual_text(
          Decorations.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          Decorations.t()
  defp add_border_virtual_text(decs, start_line, line_count, border_fg) do
    Enum.reduce(0..(line_count - 1), decs, fn offset, d ->
      line = start_line + offset

      {_id, d} =
        Decorations.add_virtual_text(d, {line, 0},
          segments: [{"▎ ", [fg: border_fg]}],
          placement: :inline,
          priority: 10
        )

      d
    end)
  end

  # Spinner frame that cycles based on system time (changes each render frame)
  defp format_tool_duration(%{duration_ms: ms}) when is_integer(ms) and ms < 1000,
    do: " (#{ms}ms)"

  defp format_tool_duration(%{duration_ms: ms}) when is_integer(ms),
    do: " (#{Float.round(ms / 1000, 1)}s)"

  defp format_tool_duration(_tc), do: ""

  defp format_tool_command(%{name: "bash", args: %{"command" => cmd}}) do
    truncated = String.slice(cmd, 0, 60)
    suffix = if String.length(cmd) > 60, do: "...", else: ""
    " (command: \"#{truncated}#{suffix}\")"
  end

  defp format_tool_command(%{name: "read", args: %{"path" => path}}) do
    " (#{path})"
  end

  defp format_tool_command(%{name: "write", args: %{"path" => path}}) do
    " (#{path})"
  end

  defp format_tool_command(%{name: "edit", args: %{"path" => path}}) do
    " (#{path})"
  end

  defp format_tool_command(_tc), do: ""

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  defp spinner_frame do
    idx = rem(div(System.monotonic_time(:millisecond), 100), length(@spinner_frames))
    Enum.at(@spinner_frames, idx)
  end

  defp apply_user_decorations(decs, line, line_count, theme) do
    {_id, decs} =
      Decorations.add_block_decoration(decs, line,
        placement: :above,
        render: fn _w -> [{"▎ You", [fg: theme.user_border, bold: true, bg: theme.header_bg]}] end,
        priority: 10
      )

    # Colored border prefix on each content line
    add_border_virtual_text(decs, line, line_count, theme.user_border)
  end
end
