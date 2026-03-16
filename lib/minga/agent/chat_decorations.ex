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
    add_code_block_highlights(decs, text, line, theme.code_bg)
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
