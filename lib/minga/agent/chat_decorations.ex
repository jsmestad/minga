defmodule Minga.Agent.ChatDecorations do
  @moduledoc """
  Produces decorations for the `*Agent*` buffer based on chat messages.

  Translates the agent session's message list into highlight ranges,
  block decorations, virtual text, and fold regions on the `*Agent*`
  buffer. The buffer rendering pipeline handles the actual drawing.

  This replaces the standalone `ChatRenderer` which built draw commands
  directly. By using decorations, the chat gets visual mode selection,
  yank, mouse drag, and search for free via the standard buffer pipeline.
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
      decs = Decorations.clear(decs)
      build_decorations(decs, messages, line_offsets, agent_theme, opts)
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
    offset_map = Map.new(line_offsets, fn {idx, start, count} -> {idx, {start, count}} end)

    last_idx = length(messages) - 1

    messages
    |> Enum.with_index()
    |> Enum.reduce(decs, fn {msg, idx}, d ->
      case Map.get(offset_map, idx) do
        {start_line, line_count} ->
          is_last = idx == last_idx
          apply_message_decorations(d, msg, start_line, line_count, theme, streaming and is_last)

        nil ->
          d
      end
    end)
  end

  # ── Per-message decoration builders ──────────────────────────────────────

  defp apply_message_decorations(
         decs,
         {:user, _text, _attachments},
         line,
         line_count,
         theme,
         _streaming
       ) do
    apply_user_decorations(decs, line, line_count, theme)
  end

  defp apply_message_decorations(decs, {:user, _text}, line, line_count, theme, _streaming) do
    apply_user_decorations(decs, line, line_count, theme)
  end

  defp apply_message_decorations(decs, {:assistant, text}, line, line_count, theme, streaming) do
    {_id, decs} =
      Decorations.add_block_decoration(decs, line,
        placement: :above,
        render: fn _w ->
          [{"▎ Agent", [fg: theme.assistant_border, bold: true, bg: theme.header_bg]}]
        end,
        priority: 10
      )

    {_id, decs} =
      Decorations.add_highlight(decs, {line, 0}, {line + line_count, 0},
        style: [bg: theme.header_bg],
        priority: -20,
        group: :chat_bg
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

    decs = add_border_highlights(decs, line, line_count, theme.assistant_border)

    # Code block background highlights (lines between ``` fences)
    md_text = "## Agent\n\n#{text}"
    add_code_block_highlights(decs, md_text, line, theme.code_bg)
  end

  defp apply_message_decorations(
         decs,
         {:thinking, _text, collapsed},
         line,
         line_count,
         theme,
         _streaming
       ) do
    if collapsed do
      {_id, decs} =
        Decorations.add_fold_region(decs, line, line + line_count - 1,
          closed: true,
          placeholder: fn _s, _e, _w ->
            [{"💭 Thinking (#{line_count} lines)...", [fg: theme.thinking_fg, italic: true]}]
          end
        )

      decs
    else
      decs
    end
  end

  defp apply_message_decorations(decs, {:tool_call, tc}, line, line_count, theme, _streaming) do
    status_icon =
      case tc.status do
        :running -> "⟳"
        :complete -> "✓"
        :error -> "✗"
      end

    status_fg =
      case tc.status do
        :running -> theme.status_tool
        :complete -> theme.tool_header
        :error -> theme.status_error
      end

    has_result = tc.result != ""

    # Block decoration: tool header
    {_id, decs} =
      Decorations.add_block_decoration(decs, line,
        placement: :above,
        render: fn _w ->
          [{"┌─ #{status_icon} #{tc.name}", [fg: status_fg, bold: true]}]
        end,
        priority: 5
      )

    # Fold region for tool output (collapsible with za)
    decs =
      if has_result and tc.status != :running and line_count > 2 do
        # Header takes first few lines; fold the rest (tool output)
        header_lines = 1
        fold_start = line + header_lines
        fold_end = line + line_count - 1

        if fold_end > fold_start do
          {_id, decs} =
            Decorations.add_fold_region(decs, fold_start, fold_end,
              closed: false,
              placeholder: fn _s, _e, _w ->
                [
                  {"└─ #{status_icon} #{tc.name} (#{line_count - 1} lines)",
                   [fg: status_fg, italic: true]}
                ]
              end
            )

          decs
        else
          decs
        end
      else
        decs
      end

    decs
  end

  defp apply_message_decorations(decs, {:usage, _usage}, _line, _line_count, _theme, _streaming),
    do: decs

  defp apply_message_decorations(decs, _other, _line, _line_count, _theme, _streaming), do: decs

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
  @spec add_border_highlights(
          Decorations.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          Decorations.t()
  defp add_border_highlights(decs, start_line, line_count, border_fg) do
    Enum.reduce(0..(line_count - 1), decs, fn offset, d ->
      line = start_line + offset

      {_id, d} =
        Decorations.add_highlight(d, {line, 0}, {line, 2},
          style: [fg: border_fg],
          priority: -15,
          group: :chat_border
        )

      d
    end)
  end

  # Spinner frame that cycles based on system time (changes each render frame)
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

    {_id, decs} =
      Decorations.add_highlight(decs, {line, 0}, {line + line_count, 0},
        style: [bg: theme.header_bg],
        priority: -20,
        group: :chat_bg
      )

    # Colored border prefix on each content line
    add_border_highlights(decs, line, line_count, theme.user_border)
  end
end
