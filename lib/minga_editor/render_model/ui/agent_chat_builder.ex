defmodule MingaEditor.RenderModel.UI.AgentChatBuilder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec, as: AgentChatMessageCodec
  alias Minga.Frontend.Adapter.GUI.EncodingError
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
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Renderer.TranscriptUpdate
  alias MingaEditor.RenderModel.UI.AgentChatResident
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Agent.View.PromptFrame
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.TabBar
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion
  alias Minga.RenderModel.UI.AgentChat.StartRemedy
  alias Minga.Keymap.Scope.Agent, as: AgentScope
  alias Minga.RenderModel.UI.AgentChat.ToolArgSummary
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.AgentChat.ToolStep
  alias Minga.RenderModel.UI.AgentChat.Usage
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Window.Content

  @typep approval :: PublicApproval.t()

  @composer_unavailable "The composer is unavailable. Switch away from this tab and return to reopen it."

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
    {messages, truncated?, epoch} = resident_transcript(ctx)

    %AgentChat{
      visible?: true,
      lifecycle: {:failed, @composer_unavailable, nil},
      lifecycle_headline: "Agent unavailable",
      prompt_visible_rows: 0,
      resident_messages: messages,
      resident_truncated?: truncated?,
      transcript_epoch: epoch
    }
  end

  defp build_visible(ctx, lifecycle) do
    agent_ui = ctx.workspace.agent_ui

    {presentation, session} =
      chat_presentation(
        lifecycle,
        remedy_focus(ctx.intent.frame.editing_model, ctx.workspace.editing.mode, agent_ui)
      )

    shell_agent = TraditionalState.agent(ctx.intent.frame.shell_state)
    panel = agent_ui.panel

    projection = ctx.prompt.projection
    prompt_text = Enum.join(projection.lines, "\n")
    {cursor_line, cursor_col} = projection.cursor
    visible_rows = projection.visible_rows

    {resident_messages, resident_truncated?, transcript_epoch} = resident_transcript(ctx)
    stop_target = bound_turn(shell_agent.stop_target, session)
    continue_target = bound_turn(shell_agent.continue_target, session)

    %AgentChat{
      visible?: true,
      lifecycle: presentation,
      lifecycle_headline: lifecycle_headline(lifecycle),
      draft_note: draft_note(lifecycle, visible_rows, ctx.intent.frame.editing_model),
      status: chat_status(ctx.intent.frame.shell_state, agent_ui, presentation),
      model_name: UIState.model_label(agent_ui),
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
      stop_target: stop_target,
      continue_target: continue_target,
      queue_target: queue_target(shell_agent.queue_target, agent_ui.draft_save, session),
      prompt_completion: build_prompt_completion(panel),
      input_focused: composer_focused?(ctx, panel),
      composer_hints: composer_hints(ctx, panel, stop_target != nil, continue_target != nil),
      resident_messages: resident_messages,
      resident_truncated?: resident_truncated?,
      transcript_epoch: transcript_epoch
    }
  end

  # The resident root was admitted with this attempt's intent. Enumerating its
  # selected suffix is the still-unmigrated adapter boundary; no body is
  # converted or sized here.
  @spec resident_transcript(Context.t()) :: {[AgentChat.message()], boolean(), non_neg_integer()}
  defp resident_transcript(%Context{workspace: %{agent_transcript: %AgentChatResident{} = root}}) do
    {messages, truncated?} = AgentChatResident.resident_messages(root)
    {messages, truncated?, root.epoch}
  end

  defp resident_transcript(%Context{}), do: {[], false, 0}

  @doc """
  Admits one Editor transcript update into the renderer-local resident root.

  Runs at renderer admission, in mailbox order, before frames are coalesced. Decorations come from the same intent: the displayed Session's pending approval, the retained-output scope and the registry footer. Only changed entries and exactly affected decorated rows are derived and sized.
  """
  @spec admit(AgentChatResident.t() | nil, TranscriptUpdate.t() | nil, Intent.t()) ::
          AgentChatResident.admission()
  def admit(root, nil, %Intent{}), do: {:ok, root}

  def admit(root, update, %Intent{} = intent) do
    AgentChatResident.admit(root, update, resident_context(update_identity(update), intent))
  end

  @spec update_identity(TranscriptUpdate.t()) :: TranscriptUpdate.identity()
  defp update_identity(update), do: elem(update, 1)

  @spec resident_context(TranscriptUpdate.identity(), Intent.t()) :: AgentChatResident.context()
  defp resident_context(identity, %Intent{} = intent) do
    agent_ui = intent.workspace.agent_ui
    shell_state = intent.frame.shell_state
    session = transcript_session(agent_ui)
    approval = pending_approval(shell_pending_approval(shell_state), session)
    scope = retained_scope(agent_ui.connection, shell_state, session, identity)

    %{
      scope: scope,
      approval: approval_target(approval),
      footer: resident_footer(identity, session),
      max_bytes: Minga.Config.get(:agent_transcript_resident_max_bytes),
      derive: fn item, decoration ->
        item |> maybe_style_message(decoration) |> to_core_message(scope)
      end,
      measure: &measure_entry/1,
      tool_id: &item_tool_id/1,
      decoratable?: &running_tool?/1
    }
  end

  # The codec rejects out-of-range fields instead of truncating them. Showing a
  # bounded notice under the same message ID keeps admission total, so Editor
  # and renderer bases stay aligned and no other presentation is shown.
  @spec measure_entry(AgentChat.message()) ::
          {:ok, pos_integer()} | {:fallback, AgentChat.message(), pos_integer(), atom()}
  defp measure_entry({id, _body} = message) do
    {:ok, AgentChatMessageCodec.resident_entry_size(message)}
  rescue
    error in EncodingError ->
      fallback = {id, {:system, "Message too large to display", :error}}
      {:fallback, fallback, AgentChatMessageCodec.resident_entry_size(fallback), error.field}
  end

  # A missing composer or a non-conversation lifecycle presents no Session
  # controls, matching the composer-unavailable chat model.
  @spec transcript_session(UIState.t()) :: pid() | nil
  defp transcript_session(%UIState{panel: %Panel{prompt_buffer: nil}}), do: nil
  defp transcript_session(%UIState{chat_lifecycle: {:conversation, session}}), do: session
  defp transcript_session(%UIState{}), do: nil

  @spec shell_pending_approval(term()) :: PendingApproval.t() | nil
  defp shell_pending_approval(%TraditionalState{} = shell_state),
    do: TraditionalState.agent(shell_state).pending_approval

  defp shell_pending_approval(_shell_state), do: nil

  @spec approval_target(approval() | nil) :: {String.t(), approval()} | nil
  defp approval_target(%PublicApproval{target: %ApprovalTarget{tool_call_id: id}} = approval),
    do: {id, approval}

  defp approval_target(nil), do: nil

  # Without a presentation or a Session there is no transcript, so no footer.
  @spec resident_footer(TranscriptUpdate.identity(), pid() | nil) :: [AgentChat.message()]
  defp resident_footer(nil, nil), do: []

  defp resident_footer(_identity, _session),
    do: SemanticUIRegistry.transcript_enrichments(SemanticUIRegistry.default_table())

  @spec item_tool_id(TranscriptProjection.Index.item()) :: String.t() | nil
  defp item_tool_id({_id, {:tool_call, %ToolCall{id: id}}, _style}), do: id
  defp item_tool_id(_item), do: nil

  @spec running_tool?(TranscriptProjection.Index.item()) :: boolean()
  defp running_tool?({_id, {:tool_call, %ToolCall{status: :running}}, _style}), do: true
  defp running_tool?(_item), do: false

  @spec chat_presentation(UIState.chat_lifecycle(), AgentScope.start_remedy_focus()) ::
          {AgentChat.lifecycle(), pid() | nil}
  defp chat_presentation({:conversation, session}, _focus), do: {:conversation, session}

  defp chat_presentation({:failed, %StartFailure{message: message, remedy: remedy}}, focus),
    do: {{:failed, message, start_remedy(remedy, focus)}, nil}

  defp chat_presentation(lifecycle, _focus) when lifecycle in [:starting, :unavailable],
    do: {lifecycle, nil}

  # The notice headline says what happened to the tab. A failed lifecycle's
  # headline is its StartFailure's own, the one the context card also shows.
  @spec lifecycle_headline(UIState.chat_lifecycle()) :: String.t()
  defp lifecycle_headline({:conversation, _session}), do: ""
  defp lifecycle_headline(:starting), do: "Starting Agent"
  defp lifecycle_headline({:failed, %StartFailure{headline: headline}}), do: headline
  defp lifecycle_headline(:unavailable), do: "No active Agent session"

  # The draft survives a failed or missing session; say so only where a
  # composer is shown, and name the new-session key only when one is bound for
  # this editing model.
  @spec draft_note(UIState.chat_lifecycle(), non_neg_integer(), atom()) :: String.t()
  defp draft_note({:failed, _failure}, visible_rows, editing_model) when visible_rows > 0,
    do: saved_draft_note(editing_model)

  defp draft_note(:unavailable, visible_rows, editing_model) when visible_rows > 0,
    do: saved_draft_note(editing_model)

  defp draft_note(_lifecycle, _visible_rows, _editing_model), do: ""

  @spec saved_draft_note(atom()) :: String.t()
  defp saved_draft_note(editing_model) do
    case new_session_key_hint(editing_model) do
      nil -> "Your draft is saved."
      key -> "Your draft is saved. #{key} starts a new session."
    end
  end

  @spec new_session_key_hint(atom()) :: String.t() | nil
  defp new_session_key_hint(editing_model) do
    AgentScope.new_session_key_hint(
      Minga.Keymap.leader_trie(),
      editing_model,
      Minga.Config.get(:space_leader)
    )
  end

  # Key dispatch resolves CUA keys through one trie, a focused Vim composer's
  # keys through the prompt (Enter runs the remedy), and other Vim keys through
  # chat navigation (`r` runs it), so the hint follows the same facts.
  @spec remedy_focus(atom(), atom(), UIState.t()) :: AgentScope.start_remedy_focus()
  defp remedy_focus(:cua, _mode, _ui), do: :cua

  defp remedy_focus(_vim, :insert, %UIState{panel: %Panel{input_focused: true}}),
    do: :composer_insert

  defp remedy_focus(_vim, _mode, %UIState{panel: %Panel{input_focused: true}}), do: :composer
  defp remedy_focus(_vim, _mode, %UIState{}), do: :chat

  # The label and key hint come from the BEAM so no frontend authors remedy copy;
  # the hint is the key the Agent scope binds at the current focus.
  @spec start_remedy(StartFailure.remedy() | nil, AgentScope.start_remedy_focus()) ::
          StartRemedy.t() | nil
  defp start_remedy(nil, _focus), do: nil
  defp start_remedy({:retry, _target}, focus), do: start_remedy(:retry, "Retry", focus)

  defp start_remedy(:set_up_provider, focus),
    do: start_remedy(:set_up_provider, "Set up provider", focus)

  @spec start_remedy(StartRemedy.kind(), String.t(), AgentScope.start_remedy_focus()) ::
          StartRemedy.t()
  defp start_remedy(kind, label, focus),
    do: %StartRemedy{kind: kind, label: label, key_hint: AgentScope.start_remedy_key_hint(focus)}

  # A live conversation shows the same Agent status as the workspace pill and
  # the activity strip; a failed start needs the user; no session is idle.
  @spec chat_status(term(), UIState.t(), AgentChat.lifecycle()) :: atom()
  defp chat_status(shell_state, agent_ui, :conversation),
    do: WorkspaceStatus.active(shell_state, agent_ui)

  defp chat_status(_shell_state, _agent_ui, {:failed, _reason, _remedy}), do: :needs_you
  defp chat_status(_shell_state, _agent_ui, _unavailable), do: :idle

  # The composer has the keys only while it is focused and nothing (a picker, an
  # overlay) holds them above it.
  @spec composer_focused?(Context.t(), Panel.t()) :: boolean()
  defp composer_focused?(ctx, panel) do
    panel.input_focused and ctx.intent.frame.focus_owner.responder == :editor_view and
      ctx.intent.frame.focus_owner.surface == :agent
  end

  # The focused composer's key hints come from the Agent scope, which binds the
  # keys they name; a composer without the keys shows none.
  @spec composer_hints(Context.t(), Panel.t(), boolean(), boolean()) :: [
          AgentChat.composer_hint()
        ]
  defp composer_hints(ctx, panel, stoppable?, continuable?) do
    if composer_focused?(ctx, panel),
      do: focused_composer_hints(ctx, stoppable?, continuable?),
      else: []
  end

  # Stop is hinted exactly when this conversation has a turn to stop: the stop
  # target is what the stop command acts on, so the hint cannot name a key that
  # does nothing. It covers a turn that waits for an approval, a turn in plan
  # mode and a turn that reported an error and is still running, none of which
  # the runtime status reports as working.
  @spec focused_composer_hints(Context.t(), boolean(), boolean()) :: [
          AgentChat.composer_hint()
        ]
  defp focused_composer_hints(ctx, stoppable?, continuable?) do
    AgentScope.composer_key_hints(
      composer_focus(ctx.intent.frame.editing_model, ctx.workspace.editing.mode),
      native_gui: MingaEditor.Frontend.gui?(ctx.intent.frame.capabilities),
      working: stoppable?,
      stopped: continuable?,
      remedy: UIState.start_remedy(ctx.workspace.agent_ui) != nil
    )
  end

  @spec composer_focus(atom(), atom()) :: AgentScope.composer_focus()
  defp composer_focus(:cua, _mode), do: :cua
  defp composer_focus(_vim, :insert), do: :insert
  defp composer_focus(_vim, :normal), do: :normal
  defp composer_focus(_vim, _mode), do: :other_mode

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

  @spec bound_turn({pid(), {String.t(), String.t()}} | nil, pid() | nil) ::
          {String.t(), String.t()} | nil
  defp bound_turn({session, target}, session), do: target
  defp bound_turn(_target, _session), do: nil

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

  @spec retained_scope(term(), term(), pid() | nil, reference() | nil) ::
          RetainedOutputTarget.scope() | nil
  defp retained_scope(
         %{target: %{session: session, epoch: epoch}},
         shell_state,
         session,
         generation
       )
       when is_pid(session) and is_reference(generation) and
              is_struct(shell_state, TraditionalState) do
    case TraditionalState.tab_bar(shell_state) do
      %TabBar{} = tabs -> {TabBar.active_workspace_id(tabs), epoch, generation}
      nil -> nil
    end
  end

  defp retained_scope(_connection, _shell_state, _session, _generation), do: nil

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
    status = tool_call_status(tc)

    %ToolCallView{
      name: tc.name,
      summary: tool_call_summary(tc),
      step: ToolStep.sentence(tc.name, tc.args, status),
      state: ToolStep.state(status),
      result: tc.result,
      status: status,
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
      # The card's headline: the question in the decision's words, from the admitted call.
      summary: ToolStep.question(approval.name, approval.args),
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
  defp tool_call_summary(%ToolCall{name: name, args: args}),
    do: ToolArgSummary.summarize(name, args)
end
