defmodule MingaEditor.RenderModel.UI.AgentChatBuilder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec, as: AgentChatMessageCodec
  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.ToolApproval
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage
  alias MingaEditor.Agent.SemanticUI.Registry, as: SemanticUIRegistry
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.UI.Theme
  alias Minga.Buffer
  alias Minga.Editing.Scroll
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion
  alias Minga.RenderModel.UI.AgentChat.ToolArgSummary
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.AgentChat.Usage
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Window.Content

  @spec build(Context.t()) :: AgentChat.t()
  def build(ctx) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)
    session = active_session(ctx)

    if is_agent_chat && session do
      build_visible(ctx, session)
    else
      %AgentChat{visible?: false}
    end
  end

  @spec active_session(Context.t()) :: pid() | nil
  defp active_session(ctx) do
    ctx.shell.active_session(ctx.shell_state)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @spec build_visible(Context.t(), pid()) :: AgentChat.t()
  defp build_visible(ctx, session) do
    panel = ctx.agent_ui.panel
    view = ctx.agent_ui.view

    prompt_text = safe_prompt_content(panel.prompt_buffer)
    {cursor_line, cursor_col} = UIState.input_cursor(panel)
    inner_width = max(ctx.viewport.cols - 10, 20)
    visible_rows = PromptRenderWindow.visible_rows(panel, inner_width)

    {full_pairs, full_styled_cache} = full_messages_for_model(panel, session, ctx.theme)

    {messages_with_ids, styled_cache} =
      visible_message_slice(panel, full_pairs, full_styled_cache)

    pending_approval = AgentAccess.agent(ctx).pending_approval

    gui_messages =
      messages_with_ids
      |> build_gui_messages(styled_cache, pending_approval)
      |> maybe_append_transcript_enrichments(panel, SemanticUIRegistry.default_table())

    # Resident transcript (#2654): the display_start_index-scoped conversation for
    # the gui_agent_transcript (0x86) stream. It is never sliced by scroll; this
    # builder applies the configured byte-cap suffix bound and records whether
    # older complete messages were omitted. `messages` above stays windowed for
    # the legacy gui_agent_chat (0x78) section during the dual-emit transition.
    {resident_messages, resident_truncated?} =
      full_pairs
      |> build_gui_messages(full_styled_cache, pending_approval)
      |> append_resident_transcript_enrichments(SemanticUIRegistry.default_table())
      |> select_resident_messages()

    help_visible = view.help_visible

    help_groups =
      if help_visible do
        Minga.Keymap.Scope.Agent.help_groups(UIState.View.focus(view))
      else
        []
      end

    log_agent_chat_message_stats(gui_messages)

    %AgentChat{
      visible?: true,
      status: AgentAccess.agent(ctx).runtime.status || :idle,
      model_name: display_model_name(panel.model_name),
      thinking_level: panel.thinking_level,
      prompt: prompt_text,
      prompt_line_count: UIState.input_line_count(panel),
      prompt_cursor_line: cursor_line,
      prompt_cursor_col: cursor_col,
      prompt_vim_mode: ctx.editing.mode,
      prompt_visible_rows: visible_rows,
      prompt_completion: build_prompt_completion(panel),
      help_visible?: help_visible,
      help_groups: help_groups,
      input_focused: panel.input_focused,
      messages: gui_messages,
      resident_messages: resident_messages,
      resident_truncated?: resident_truncated?,
      transcript_epoch: transcript_epoch(session, panel)
    }
  end

  @doc false
  @spec select_resident_messages([AgentChat.message()], pos_integer()) ::
          {[AgentChat.message()], boolean()}
  def select_resident_messages(
        messages,
        max_bytes \\ Minga.Config.get(:agent_transcript_resident_max_bytes)
      ) do
    AgentChat.resident_suffix(messages, max_bytes, &AgentChatMessageCodec.resident_entry_size/1)
  end

  # Opaque change token for the resident transcript stream. Flips on structural
  # change (session switch → new pid; compaction/clear_display → new
  # display_start_index), which the 0x86 encoder maps to a full store replace.
  @spec transcript_epoch(pid(), MingaEditor.Agent.UIState.Panel.t()) :: non_neg_integer()
  defp transcript_epoch(session, panel) do
    :erlang.phash2({session, panel.display_start_index})
  end

  @spec display_model_name(String.t()) :: String.t()
  defp display_model_name(model) when model in ["", "unknown"], do: "No model configured"
  defp display_model_name(model), do: model

  @spec log_agent_chat_message_stats([{pos_integer(), term()}]) :: :ok
  defp log_agent_chat_message_stats(messages) do
    {styled, plain} =
      Enum.reduce(messages, {0, 0}, fn
        {_, {:styled_assistant, _}}, {s, p} -> {s + 1, p}
        {_, {:assistant_markdown, _}}, {s, p} -> {s + 1, p}
        {_, {:styled_tool_call, _, _}}, {s, p} -> {s + 1, p}
        {_, {:assistant, _}}, {s, p} -> {s, p + 1}
        _, acc -> acc
      end)

    Minga.Log.debug(
      :render,
      "[gui] sending agent chat: #{length(messages)} msgs (#{styled} styled, #{plain} plain assistant)"
    )
  end

  @spec build_prompt_completion(MingaEditor.Agent.UIState.Panel.t()) :: PromptCompletion.t() | nil
  defp build_prompt_completion(%{mention_completion: %{candidates: candidates} = comp})
       when is_list(candidates) and candidates != [] do
    {type, formatted_candidates} =
      case comp[:slash_candidates] do
        slash when is_list(slash) and slash != [] ->
          {:slash, slash}

        _ ->
          {:mention, candidates}
      end

    %PromptCompletion{
      type: type,
      candidates: formatted_candidates,
      selected: comp.selected,
      anchor_line: comp.anchor_line,
      anchor_col: comp.anchor_col
    }
  end

  defp build_prompt_completion(_panel), do: nil

  @spec safe_prompt_content(pid() | nil) :: String.t()
  defp safe_prompt_content(nil), do: ""

  defp safe_prompt_content(buf) do
    Buffer.content(buf) |> String.trim_trailing("\n")
  catch
    :exit, _ -> ""
  end

  @spec full_messages_for_model(MingaEditor.Agent.UIState.Panel.t(), pid(), Theme.t() | nil) ::
          {[{pos_integer(), term()}], [term()] | nil}
  defp full_messages_for_model(panel, session, theme) do
    pairs = displayed_message_pairs(panel, session)
    styled_cache = resolve_styled_cache(panel, theme)
    {pairs, styled_cache}
  end

  @spec resolve_styled_cache(MingaEditor.Agent.UIState.Panel.t(), Theme.t() | nil) ::
          [term()] | nil
  defp resolve_styled_cache(panel, theme) do
    if panel.cached_styled_fingerprint == styled_cache_fingerprint(theme) do
      panel.cached_styled_messages
    else
      nil
    end
  end

  @spec styled_cache_fingerprint(Theme.t() | nil) :: non_neg_integer()
  defp styled_cache_fingerprint(nil), do: 0

  defp styled_cache_fingerprint(%Theme{syntax: syntax}),
    do: Panel.styled_cache_fingerprint(syntax)

  @spec displayed_message_pairs(MingaEditor.Agent.UIState.Panel.t(), pid()) :: [
          {pos_integer(), term()}
        ]
  defp displayed_message_pairs(%{cached_display_message_pairs: pairs}, _session)
       when is_list(pairs) and pairs != [],
       do: pairs

  defp displayed_message_pairs(_panel, session) do
    AgentSession.messages_with_ids(session)
  catch
    :exit, _ -> []
  end

  @spec visible_message_slice(
          MingaEditor.Agent.UIState.Panel.t(),
          [{pos_integer(), term()}],
          [term()] | nil
        ) ::
          {[{pos_integer(), term()}], [term()] | nil}
  defp visible_message_slice(%{scroll: %Scroll{pinned: true}}, pairs, styled_cache),
    do: {pairs, styled_cache}

  defp visible_message_slice(%{cached_line_index: []}, pairs, styled_cache),
    do: {pairs, styled_cache}

  defp visible_message_slice(
         %{cached_line_index: line_index, scroll: %Scroll{} = scroll},
         pairs,
         styled_cache
       ) do
    total_lines = length(line_index)
    visible_height = scroll.metrics.visible_height
    offset = Scroll.resolve(scroll, total_lines, visible_height)
    target_line = min(offset + visible_height - 1, total_lines - 1)

    {target_message_index, _line_type} =
      Enum.at(line_index, target_line, {length(pairs) - 1, :text})

    count = min(target_message_index + 1, length(pairs))

    {Enum.take(pairs, count), take_styled_cache(styled_cache, count)}
  end

  @spec take_styled_cache([term()] | nil, non_neg_integer()) :: [term()] | nil
  defp take_styled_cache(nil, _count), do: nil

  defp take_styled_cache(styled_cache, count) when is_list(styled_cache),
    do: Enum.take(styled_cache, count)

  @spec maybe_append_transcript_enrichments(
          [{pos_integer(), term()}],
          MingaEditor.Agent.UIState.Panel.t(),
          SemanticUIRegistry.table()
        ) :: [{pos_integer(), term()}]
  defp maybe_append_transcript_enrichments(
         messages,
         %{scroll: %Scroll{pinned: false}},
         _agent_ui_registry
       ),
       do: messages

  defp maybe_append_transcript_enrichments(messages, _panel, agent_ui_registry) do
    messages ++ SemanticUIRegistry.transcript_enrichments(agent_ui_registry)
  end

  # The resident transcript is never windowed, so its enrichments always sit at
  # the true end (independent of scroll pin state).
  @spec append_resident_transcript_enrichments(
          [{pos_integer(), term()}],
          SemanticUIRegistry.table()
        ) :: [{pos_integer(), term()}]
  defp append_resident_transcript_enrichments(messages, agent_ui_registry) do
    messages ++ SemanticUIRegistry.transcript_enrichments(agent_ui_registry)
  end

  @spec build_gui_messages([{pos_integer(), term()}], [term()] | nil, map() | nil) :: [
          {pos_integer(), term()}
        ]
  defp build_gui_messages(messages_with_ids, nil, pending_approval) do
    Enum.map(messages_with_ids, fn message ->
      message |> maybe_inline_approval(pending_approval) |> to_core_message()
    end)
  end

  defp build_gui_messages(messages_with_ids, styled_cache, pending_approval)
       when is_list(styled_cache) do
    padded = pad_cache(styled_cache, length(messages_with_ids))

    messages_with_ids
    |> Enum.zip(padded)
    |> Enum.map(fn message ->
      message |> maybe_style_message(pending_approval) |> to_core_message()
    end)
  end

  @spec maybe_style_message({{pos_integer(), term()}, term()}, map() | nil) ::
          {pos_integer(), term()}
  defp maybe_style_message({{id, {:assistant, _text} = msg}, nil}, _pending_approval),
    do: {id, msg}

  defp maybe_style_message(
         {{id, {:assistant, _text}}, %{markdown_blocks: blocks}},
         _pending_approval
       )
       when is_list(blocks) and blocks != [] do
    {id, {:assistant_markdown, blocks}}
  end

  defp maybe_style_message(
         {{id, {:assistant, _text}}, %{styled_lines: styled_lines}},
         _pending_approval
       )
       when is_list(styled_lines) do
    {id, {:styled_assistant, styled_lines}}
  end

  defp maybe_style_message({{id, {:assistant, _text}}, styled_lines}, _pending_approval)
       when is_list(styled_lines) do
    {id, {:styled_assistant, styled_lines}}
  end

  defp maybe_style_message({{id, {:tool_call, tc} = msg}, cache_entry}, pending_approval) do
    case maybe_inline_approval({id, msg}, pending_approval) do
      {^id, {:approval_tool_call, _tc, _approval}} = approval_message ->
        approval_message

      {^id, {:tool_call, _tc}} ->
        maybe_styled_tool_call(id, tc, cache_entry, msg)

      unchanged ->
        unchanged
    end
  end

  defp maybe_style_message({{id, msg}, _cache_entry}, _pending_approval), do: {id, msg}

  @spec maybe_styled_tool_call(pos_integer(), ToolCall.t(), term(), term()) ::
          {pos_integer(), term()}
  defp maybe_styled_tool_call(id, tc, %{styled_lines: styled_lines}, _fallback)
       when is_list(styled_lines) do
    {id, {:styled_tool_call, tc, styled_lines}}
  end

  defp maybe_styled_tool_call(id, tc, styled_lines, _fallback) when is_list(styled_lines) do
    {id, {:styled_tool_call, tc, styled_lines}}
  end

  defp maybe_styled_tool_call(id, _tc, _cache_entry, fallback), do: {id, fallback}

  @spec maybe_inline_approval({pos_integer(), term()}, map() | nil) :: {pos_integer(), term()}
  defp maybe_inline_approval({id, {:tool_call, tc}}, %{tool_call_id: tool_call_id} = approval)
       when tc.id == tool_call_id do
    {id, {:approval_tool_call, tc, approval}}
  end

  defp maybe_inline_approval({id, msg}, _pending_approval), do: {id, msg}

  @spec pad_cache([term()], non_neg_integer()) :: [term()]
  defp pad_cache(cache, target_len) do
    if Enum.count(cache) >= target_len do
      cache
    else
      cache ++ List.duplicate(nil, target_len - Enum.count(cache))
    end
  end

  # ── Agent-struct → core-view conversion ──
  #
  # Layer 1 reads MingaAgent and resolves every agent struct into the core
  # views the encoder serializes. After this pass the GUI encoder never sees a
  # MingaAgent struct.

  @spec to_core_message({pos_integer(), term()}) :: {pos_integer(), term()}
  defp to_core_message({id, body}), do: {id, to_core_body(body)}

  @spec to_core_body(term()) :: term()
  defp to_core_body({:tool_call, %ToolCall{} = tc}), do: {:tool_call, tool_call_view(tc)}

  defp to_core_body({:styled_tool_call, %ToolCall{} = tc, styled_lines}),
    do: {:styled_tool_call, tool_call_view(tc), styled_lines}

  defp to_core_body({:assistant_markdown, blocks}), do: {:assistant_markdown, blocks}

  defp to_core_body({:approval_tool_call, %ToolCall{} = tc, approval}),
    do: {:approval_tool_call, approval_view(tc, approval)}

  defp to_core_body({:usage, %TurnUsage{} = usage}), do: {:usage, usage_view(usage)}

  defp to_core_body(body), do: body

  @spec tool_call_view(ToolCall.t()) :: ToolCallView.t()
  defp tool_call_view(%ToolCall{} = tc) do
    preview = tc.preview || ToolApproval.build_transcript_preview(tc.name, tc.args)

    %ToolCallView{
      name: tc.name,
      summary: tool_call_summary(tc),
      result: tc.result,
      status: tc.status,
      is_error: tc.is_error,
      collapsed: tc.collapsed,
      duration_ms: tc.duration_ms,
      auto_approved_scope: tc.auto_approved_scope,
      preview_kind: Map.get(preview, :kind, :args),
      preview_lines: Map.get(preview, :lines, [])
    }
  end

  @spec approval_view(ToolCall.t(), map()) :: ApprovalView.t()
  defp approval_view(%ToolCall{} = tc, approval) do
    preview = Map.get(approval, :preview) || ToolApproval.build_preview(tc.name, tc.args)

    %ApprovalView{
      name: tc.name,
      tool_call_id: Map.get(approval, :tool_call_id, tc.id),
      summary: Map.get(preview, :summary) || tool_call_summary(tc),
      preview_kind: Map.get(preview, :kind, :args),
      preview_lines: Map.get(preview, :lines, [])
    }
  end

  @spec usage_view(TurnUsage.t()) :: Usage.t()
  defp usage_view(%TurnUsage{} = usage) do
    %Usage{
      input: usage.input,
      output: usage.output,
      cache_read: usage.cache_read,
      cache_write: usage.cache_write,
      cost: usage.cost
    }
  end

  @spec tool_call_summary(ToolCall.t()) :: String.t()
  defp tool_call_summary(%ToolCall{name: name, args: args}) when is_map(args),
    do: ToolArgSummary.summarize(name, args)

  defp tool_call_summary(%ToolCall{name: name} = tc) do
    args = Map.get(tc, :args) || %{}
    ToolArgSummary.summarize(name, args)
  end
end
