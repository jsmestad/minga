defmodule MingaEditor.RenderModel.UI.AgentChatBuilder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec, as: AgentChatMessageCodec
  alias MingaAgent.ToolApproval
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage
  alias MingaEditor.Agent.DraftSave
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.PendingQuestion
  alias MingaEditor.Agent.RetainedOutputTarget
  alias MingaEditor.Agent.SemanticUI.Registry, as: SemanticUIRegistry
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Agent.View.PromptFrame
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.TabBar
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion
  alias Minga.RenderModel.UI.AgentChat.ToolArgSummary
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.AgentChat.Usage
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Window.Content

  @typep approval :: PublicApproval.t()

  @spec build(Context.t()) :: AgentChat.t()
  def build(ctx) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)

    if is_agent_chat do
      build_visible(ctx, ctx.workspace.agent_ui.chat_lifecycle)
    else
      %AgentChat{visible?: false}
    end
  end

  @spec build_visible(Context.t(), UIState.chat_lifecycle()) :: AgentChat.t()
  defp build_visible(%Context{prompt: nil} = ctx, _lifecycle) do
    shell_agent = TraditionalState.agent(ctx.intent.frame.shell_state)
    {messages, truncated?, epoch} = resident_transcript(ctx, shell_agent, nil)

    %AgentChat{
      visible?: true,
      lifecycle: {:failed, "composer unavailable"},
      prompt_visible_rows: 0,
      resident_messages: messages,
      resident_truncated?: truncated?,
      transcript_epoch: epoch
    }
  end

  defp build_visible(ctx, lifecycle) do
    {presentation, session} = chat_presentation(lifecycle)
    agent_ui = ctx.workspace.agent_ui
    shell_agent = TraditionalState.agent(ctx.intent.frame.shell_state)
    panel = agent_ui.panel

    projection = ctx.prompt.projection
    prompt_text = Enum.join(projection.lines, "\n")
    {cursor_line, cursor_col} = projection.cursor
    visible_rows = projection.visible_rows

    {resident_messages, resident_truncated?, transcript_epoch} =
      resident_transcript(ctx, shell_agent, session)

    %AgentChat{
      visible?: true,
      lifecycle: presentation,
      status: chat_status(shell_agent, presentation),
      model_name: Panel.chat_model_label(panel),
      thinking_level: panel.thinking_level,
      prompt: prompt_text,
      prompt_line_count: length(projection.lines),
      prompt_cursor_line: cursor_line,
      prompt_cursor_col: cursor_col,
      prompt_vim_mode: ctx.workspace.editing.mode,
      prompt_visible_rows: visible_rows,
      prompt_presentation: submission_generation(ctx.prompt),
      draft_attachment_count: attachment_count(agent_ui.draft_save),
      draft_attachment_offer: DraftSave.attachment_offer(agent_ui.draft_save),
      pending_question: pending_question(shell_agent.pending_question, session),
      stop_target: stop_target(shell_agent.stop_target, session),
      queue_target: queue_target(shell_agent.queue_target, agent_ui.draft_save, session),
      prompt_completion: build_prompt_completion(panel),
      input_focused:
        panel.input_focused and ctx.intent.frame.focus_owner.responder == :editor_view and
          ctx.intent.frame.focus_owner.surface == :agent,
      resident_messages: resident_messages,
      resident_truncated?: resident_truncated?,
      transcript_epoch: transcript_epoch
    }
  end

  @spec resident_transcript(Context.t(), MingaEditor.State.Agent.t(), pid() | nil) ::
          {[AgentChat.message()], boolean(), non_neg_integer()}
  defp resident_transcript(
         %Context{workspace: %{agent_ui: %{panel: %Panel{transcript: %{generation: nil}}}}},
         _agent,
         nil
       ),
       do: {[], false, 0}

  defp resident_transcript(ctx, agent, session) do
    agent_ui = ctx.workspace.agent_ui
    panel = agent_ui.panel
    approval = pending_approval(agent.pending_approval, session)

    retained =
      retained_scope(
        agent_ui.connection,
        ctx.intent.frame.shell_state,
        session,
        panel.transcript.generation
      )

    {messages, truncated?} =
      panel.transcript
      |> TranscriptProjection.presentation()
      |> build_gui_messages(approval, retained)
      |> append_resident_transcript_enrichments(SemanticUIRegistry.default_table())
      |> select_resident_messages()

    {messages, truncated?, TranscriptProjection.presentation_epoch(panel.transcript)}
  end

  @spec chat_presentation(UIState.chat_lifecycle()) :: {AgentChat.lifecycle(), pid() | nil}
  defp chat_presentation({:conversation, session}), do: {:conversation, session}
  defp chat_presentation(lifecycle), do: {lifecycle, nil}

  @spec chat_status(MingaEditor.State.Agent.t(), AgentChat.lifecycle()) :: atom()
  defp chat_status(agent, :conversation), do: MingaEditor.State.Agent.display_status(agent)
  defp chat_status(_agent, {:failed, _reason}), do: :error
  defp chat_status(_agent, _unavailable), do: :idle

  @spec submission_generation(PromptFrame.t()) :: pos_integer() | nil
  defp submission_generation(%PromptFrame{
         presentation: %{
           identity: {:prompt, {_, _, _}, _, _, _},
           presentation_id: generation
         }
       }),
       do: generation

  defp submission_generation(%PromptFrame{}), do: nil

  @spec attachment_count(DraftSave.t() | nil) :: non_neg_integer()
  defp attachment_count(%DraftSave{attachments: attachments}), do: length(attachments)
  defp attachment_count(nil), do: 0

  @spec pending_approval(PendingApproval.t() | nil, pid() | nil) :: PublicApproval.t() | nil
  defp pending_approval(%PendingApproval{session_pid: session, approval: approval}, session),
    do: approval

  defp pending_approval(_approval, _session), do: nil

  @spec pending_question(PendingQuestion.t() | nil, pid() | nil) ::
          {pos_integer(), String.t()} | nil
  defp pending_question(
         %PendingQuestion{session: session, offer: offer, question: question},
         session
       ),
       do: {offer, question.prompt}

  defp pending_question(_question, _session), do: nil

  @spec stop_target({pid(), {String.t(), String.t()}} | nil, pid() | nil) ::
          {String.t(), String.t()} | nil
  defp stop_target({session, target}, session), do: target
  defp stop_target(_target, _session), do: nil

  @spec queue_target(
          {pid(), MingaAgent.Session.queue_target()} | nil,
          DraftSave.t() | nil,
          pid() | nil
        ) :: MingaAgent.Session.queue_target() | nil
  defp queue_target(
         {session, {record, _, _} = target},
         %DraftSave{target: {session, record}},
         session
       ),
       do: target

  defp queue_target(_target, _save, _session), do: nil

  @spec retained_scope(term(), TraditionalState.t(), pid() | nil, reference() | nil) ::
          RetainedOutputTarget.scope() | nil
  defp retained_scope(
         %{target: %{session: session, epoch: epoch}},
         shell_state,
         session,
         generation
       )
       when is_pid(session) and is_reference(generation) do
    case TraditionalState.tab_bar(shell_state) do
      %TabBar{} = tabs -> {TabBar.active_workspace_id(tabs), epoch, generation}
      nil -> nil
    end
  end

  defp retained_scope(_connection, _shell_state, _session, _generation), do: nil

  @doc false
  @spec select_resident_messages([AgentChat.message()], pos_integer()) ::
          {[AgentChat.message()], boolean()}
  def select_resident_messages(
        messages,
        max_bytes \\ Minga.Config.get(:agent_transcript_resident_max_bytes)
      ) do
    AgentChat.resident_suffix(messages, max_bytes, &AgentChatMessageCodec.resident_entry_size/1)
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

  # The resident transcript is never windowed, so its enrichments always sit at
  # the true end (independent of scroll pin state).
  @spec append_resident_transcript_enrichments(
          [{pos_integer(), term()}],
          SemanticUIRegistry.table()
        ) :: [{pos_integer(), term()}]
  defp append_resident_transcript_enrichments(messages, agent_ui_registry) do
    messages ++ SemanticUIRegistry.transcript_enrichments(agent_ui_registry)
  end

  # A tool ID can recur; a pending target decorates only its latest transcript occurrence.
  @spec build_gui_messages(
          [TranscriptProjection.Index.item()],
          approval() | nil,
          RetainedOutputTarget.scope() | nil
        ) ::
          [{pos_integer(), term()}]
  defp build_gui_messages(items, nil, scope) do
    Enum.map(items, fn item -> item |> maybe_style_message(nil) |> to_core_message(scope) end)
  end

  defp build_gui_messages(items, %PublicApproval{} = pending_approval, scope) do
    {messages, _remaining} =
      :lists.mapfoldr(
        fn entry, approval ->
          projected = entry |> maybe_style_message(approval) |> to_core_message(scope)
          {projected, remaining_approval(entry, approval)}
        end,
        pending_approval,
        items
      )

    messages
  end

  @spec maybe_style_message(TranscriptProjection.Index.item(), approval() | nil) ::
          {pos_integer(), term()}
  defp maybe_style_message(
         {id, {:assistant, _text}, {:markdown_blocks, blocks}},
         _pending_approval
       ) do
    {id, {:assistant_markdown, blocks}}
  end

  defp maybe_style_message(
         {id, {:assistant, _text}, {:styled_lines, styled_lines}},
         _pending_approval
       ) do
    {id, {:styled_assistant, styled_lines}}
  end

  defp maybe_style_message({id, {:tool_call, tc} = msg, cache_entry}, pending_approval) do
    case maybe_inline_approval({id, msg}, pending_approval) do
      {^id, {:approval_tool_call, _tc, _approval}} = approval_message ->
        approval_message

      {^id, {:tool_call, _tc}} ->
        maybe_styled_tool_call(id, tc, cache_entry, msg)

      unchanged ->
        unchanged
    end
  end

  defp maybe_style_message({id, msg, _cache_entry}, _pending_approval), do: {id, msg}

  @spec maybe_styled_tool_call(pos_integer(), ToolCall.t(), term(), term()) ::
          {pos_integer(), term()}
  defp maybe_styled_tool_call(id, tc, {:styled_lines, styled_lines}, _fallback) do
    {id, {:styled_tool_call, tc, styled_lines}}
  end

  defp maybe_styled_tool_call(id, _tc, _cache_entry, fallback), do: {id, fallback}

  @spec remaining_approval(TranscriptProjection.Index.item(), approval() | nil) ::
          approval() | nil
  defp remaining_approval(
         {_id, {:tool_call, %ToolCall{id: tool_call_id}}, _style},
         %PublicApproval{target: %ApprovalTarget{tool_call_id: tool_call_id}}
       ),
       do: nil

  defp remaining_approval(_message, approval), do: approval

  @spec maybe_inline_approval({pos_integer(), term()}, approval() | nil) ::
          {pos_integer(), term()}
  defp maybe_inline_approval(
         {id, {:tool_call, %ToolCall{status: :running} = tc}},
         %PublicApproval{target: %ApprovalTarget{tool_call_id: tool_call_id}} = approval
       )
       when tc.id == tool_call_id do
    {id, {:approval_tool_call, tc, approval}}
  end

  defp maybe_inline_approval({id, msg}, _pending_approval), do: {id, msg}

  # ── Agent-struct → core-view conversion ──
  #
  # Layer 1 reads MingaAgent and resolves every agent struct into the core
  # views the encoder serializes. After this pass the GUI encoder never sees a
  # MingaAgent struct.

  @spec to_core_message({pos_integer(), term()}, RetainedOutputTarget.scope() | nil) ::
          {pos_integer(), term()}
  defp to_core_message({id, {:tool_call, %ToolCall{} = tc}}, scope),
    do: {id, {:tool_call, tool_call_view(tc, scope, id)}}

  defp to_core_message({id, {:styled_tool_call, %ToolCall{} = tc, styled_lines}}, scope),
    do: {id, {:styled_tool_call, tool_call_view(tc, scope, id), styled_lines}}

  defp to_core_message({id, body}, _scope), do: {id, to_core_body(body)}

  @spec to_core_body(term()) :: term()
  defp to_core_body({:assistant_markdown, blocks}), do: {:assistant_markdown, blocks}

  defp to_core_body({:approval_tool_call, %ToolCall{} = tc, approval}),
    do: {:approval_tool_call, approval_view(tc, approval)}

  defp to_core_body({:usage, %TurnUsage{} = usage}), do: {:usage, usage_view(usage)}

  defp to_core_body(body), do: body

  @spec tool_call_view(ToolCall.t(), RetainedOutputTarget.scope() | nil, pos_integer()) ::
          ToolCallView.t()
  defp tool_call_view(%ToolCall{} = tc, scope, id) do
    preview = tc.preview || ToolApproval.build_transcript_preview(tc.name, tc.args)

    %ToolCallView{
      name: tc.name,
      summary: tool_call_summary(tc),
      result: tc.result,
      status: tool_call_status(tc),
      is_error: tc.is_error,
      collapsed: tc.collapsed,
      duration_ms: tc.duration_ms,
      auto_approved_scope: tc.auto_approved_scope,
      preview_kind: Map.get(preview, :kind, :args),
      preview_lines: Map.get(preview, :lines, []),
      retained_output_offer: RetainedOutputTarget.offer(scope, id, tc)
    }
  end

  @spec tool_call_status(ToolCall.t()) :: ToolCallView.status()
  defp tool_call_status(%ToolCall{status: :error, terminal_reason: :approval_timeout}),
    do: :approval_expired

  defp tool_call_status(%ToolCall{status: status})
       when status in [:running, :complete, :error, :denied, :cancelled],
       do: status

  @spec approval_view(ToolCall.t(), approval()) :: ApprovalView.t()
  defp approval_view(
         %ToolCall{} = tc,
         %PublicApproval{
           target: %ApprovalTarget{
             session_id: session_id,
             request_id: request_id,
             tool_call_id: tool_call_id
           }
         } = approval
       ) do
    preview = approval.preview

    %ApprovalView{
      name: tc.name,
      tool_call_id: tool_call_id,
      session_id: session_id,
      request_id: request_id,
      summary: preview.summary,
      preview_kind: preview.kind,
      preview_lines: preview.lines
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
