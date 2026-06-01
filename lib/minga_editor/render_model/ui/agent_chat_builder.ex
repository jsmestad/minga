defmodule MingaEditor.RenderModel.UI.AgentChatBuilder do
  @moduledoc false

  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.ToolApproval
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias Minga.Buffer
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion
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
      build_visible(ctx)
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

  @spec build_visible(Context.t()) :: AgentChat.t()
  defp build_visible(ctx) do
    panel = ctx.agent_ui.panel
    view = ctx.agent_ui.view
    session = active_session(ctx)

    prompt_text = safe_prompt_content(panel.prompt_buffer)
    {cursor_line, cursor_col} = UIState.input_cursor(panel)
    inner_width = max(ctx.viewport.cols - 10, 20)
    visible_rows = PromptRenderWindow.visible_rows(panel, inner_width)

    messages_with_ids = displayed_message_pairs(panel, session)
    pending_approval = ctx.shell_state.agent.pending_approval

    gui_messages =
      build_gui_messages(messages_with_ids, panel.cached_styled_messages, pending_approval)

    help_visible = view.help_visible

    help_groups =
      if help_visible do
        Minga.Keymap.Scope.Agent.help_groups(view.focus)
      else
        []
      end

    log_agent_chat_message_stats(gui_messages)

    %AgentChat{
      visible?: true,
      status: ctx.shell_state.agent.runtime.status || :idle,
      model_name: panel.model_name,
      thinking_level: panel.thinking_level,
      prompt: prompt_text,
      prompt_line_count: UIState.input_line_count(panel),
      prompt_cursor_line: cursor_line,
      prompt_cursor_col: cursor_col,
      prompt_vim_mode: ctx.editing.mode,
      prompt_visible_rows: visible_rows,
      prompt_completion: build_prompt_completion(panel),
      pending_approval: nil,
      help_visible?: help_visible,
      help_groups: help_groups,
      messages: gui_messages
    }
  end

  @spec log_agent_chat_message_stats([{pos_integer(), term()}]) :: :ok
  defp log_agent_chat_message_stats(messages) do
    {styled, plain} =
      Enum.reduce(messages, {0, 0}, fn
        {_, {:styled_assistant, _}}, {s, p} -> {s + 1, p}
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

  @spec build_gui_messages([{pos_integer(), term()}], [term()] | nil, map() | nil) :: [
          {pos_integer(), term()}
        ]
  defp build_gui_messages(messages_with_ids, nil, pending_approval) do
    messages_with_ids
    |> Enum.map(&maybe_inline_approval(&1, pending_approval))
    |> Enum.map(&to_core_message/1)
  end

  defp build_gui_messages(messages_with_ids, styled_cache, pending_approval)
       when is_list(styled_cache) do
    padded = pad_cache(styled_cache, length(messages_with_ids))

    Enum.zip(messages_with_ids, padded)
    |> Enum.map(&maybe_style_message(&1, pending_approval))
    |> Enum.map(&to_core_message/1)
  end

  @spec maybe_style_message({{pos_integer(), term()}, term()}, map() | nil) ::
          {pos_integer(), term()}
  defp maybe_style_message({{id, {:assistant, _text} = msg}, nil}, _pending_approval),
    do: {id, msg}

  defp maybe_style_message({{id, {:assistant, _text}}, styled_lines}, _pending_approval),
    do: {id, {:styled_assistant, styled_lines}}

  defp maybe_style_message({{id, {:tool_call, tc} = msg}, styled_lines}, pending_approval) do
    case maybe_inline_approval({id, msg}, pending_approval) do
      {^id, {:approval_tool_call, _tc, _approval}} = approval_message ->
        approval_message

      {^id, {:tool_call, _tc}} when is_list(styled_lines) ->
        {id, {:styled_tool_call, tc, styled_lines}}

      unchanged ->
        unchanged
    end
  end

  defp maybe_style_message({{id, msg}, _cache_entry}, _pending_approval), do: {id, msg}

  @spec maybe_inline_approval({pos_integer(), term()}, map() | nil) :: {pos_integer(), term()}
  defp maybe_inline_approval({id, {:tool_call, tc}}, %{tool_call_id: tool_call_id} = approval)
       when tc.id == tool_call_id do
    {id, {:approval_tool_call, tc, approval}}
  end

  defp maybe_inline_approval({id, msg}, _pending_approval), do: {id, msg}

  @spec pad_cache([term()], non_neg_integer()) :: [term()]
  defp pad_cache(cache, target_len) when length(cache) >= target_len, do: cache
  defp pad_cache(cache, target_len), do: cache ++ List.duplicate(nil, target_len - length(cache))

  # ── Agent-struct → core-view conversion ──
  #
  # Layer 1 reads MingaAgent and resolves every agent struct into the core
  # views the encoder serializes. After this pass the GUI encoder never sees a
  # MingaAgent struct.

  @spec to_core_message({pos_integer(), term()}) :: {pos_integer(), term()}
  defp to_core_message({id, body}), do: {id, to_core_body(body)}
  defp to_core_message(body), do: to_core_body(body)

  @spec to_core_body(term()) :: term()
  defp to_core_body({:tool_call, %ToolCall{} = tc}), do: {:tool_call, tool_call_view(tc)}

  defp to_core_body({:styled_tool_call, %ToolCall{} = tc, styled_lines}),
    do: {:styled_tool_call, tool_call_view(tc), styled_lines}

  defp to_core_body({:approval_tool_call, %ToolCall{} = tc, approval}),
    do: {:approval_tool_call, approval_view(tc, approval)}

  defp to_core_body({:usage, %TurnUsage{} = usage}), do: {:usage, usage_view(usage)}

  defp to_core_body(body), do: body

  @spec tool_call_view(ToolCall.t()) :: ToolCallView.t()
  defp tool_call_view(%ToolCall{} = tc) do
    %ToolCallView{
      name: tc.name,
      summary: tool_call_summary(tc),
      result: tc.result,
      status: tc.status,
      is_error: tc.is_error,
      collapsed: tc.collapsed,
      duration_ms: tc.duration_ms,
      auto_approved_scope: tc.auto_approved_scope
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
    do: summarize_tool_args(name, args)

  defp tool_call_summary(%ToolCall{name: name} = tc) do
    args = Map.get(tc, :args) || %{}
    summarize_tool_args(name, args)
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
  defp summarize_tool_args("apply_diff", %{"path" => path}), do: path
  defp summarize_tool_args("apply_diff", %{path: path}), do: path

  defp summarize_tool_args("git_stage", %{"paths" => paths}) when is_list(paths),
    do: Enum.join(paths, ", ")

  defp summarize_tool_args("git_stage", %{paths: paths}) when is_list(paths),
    do: Enum.join(paths, ", ")

  defp summarize_tool_args("git_commit", %{"message" => msg}), do: msg
  defp summarize_tool_args("git_commit", %{message: msg}), do: msg
  defp summarize_tool_args(_name, args) when map_size(args) == 0, do: ""
  defp summarize_tool_args(_name, args), do: inspect(args, limit: 80)
end
