defmodule MingaEditor.RenderModel.UI.AgentChatBuilder do
  @moduledoc false

  alias MingaAgent.Session, as: AgentSession
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias Minga.Buffer
  alias Minga.RenderModel.UI.AgentChat
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Window.Content

  @spec build(Context.t()) :: AgentChat.t()
  def build(ctx) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)

    session =
      try do
        ctx.shell.active_session(ctx.shell_state)
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    {fp, prompt_text} =
      if is_agent_chat && session do
        panel = ctx.agent_ui.panel
        view = ctx.agent_ui.view
        styled_len = length(panel.cached_styled_messages || [])
        text = safe_prompt_content(panel.prompt_buffer)
        prompt_cursor = UIState.input_cursor(panel)
        prompt_line_count = UIState.input_line_count(panel)
        inner_width = max(ctx.viewport.cols - 10, 20)
        visible_rows = PromptRenderWindow.visible_rows(panel, inner_width)

        {:erlang.phash2(
           {:visible, ctx.shell_state.agent.runtime.status,
            ctx.shell_state.agent.pending_approval, styled_len, panel.model_name,
            panel.thinking_level, text, panel.message_version,
            length(panel.cached_display_message_pairs), view.help_visible, view.focus,
            ctx.editing.mode, prompt_cursor, prompt_line_count, visible_rows,
            panel.mention_completion}
         ), text}
      else
        {:not_visible, ""}
      end

    data = build_agent_chat_data(ctx, prompt_text)

    if data.visible do
      log_agent_chat_message_stats(data.messages)
    end

    encoded = ProtocolGUI.encode_gui_agent_chat(data)

    %AgentChat{encoded: encoded, fingerprint: fp}
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

  @spec build_prompt_completion(MingaEditor.Agent.UIState.Panel.t()) :: map() | nil
  defp build_prompt_completion(%{mention_completion: %{candidates: candidates} = comp})
       when is_list(candidates) and candidates != [] do
    {type, formatted_candidates} =
      case comp[:slash_candidates] do
        slash when is_list(slash) and slash != [] ->
          {:slash, slash}

        _ ->
          {:mention, candidates}
      end

    %{
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

  @spec build_agent_chat_data(Context.t(), String.t()) :: map()
  defp build_agent_chat_data(ctx, prompt_text) do
    active_window = Map.get(ctx.windows.map, ctx.windows.active)
    is_agent_chat = active_window != nil && Content.agent_chat?(active_window.content)

    session =
      try do
        ctx.shell.active_session(ctx.shell_state)
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    if is_agent_chat && session do
      panel = ctx.agent_ui.panel
      messages_with_ids = displayed_message_pairs(panel, session)

      styled_cache = panel.cached_styled_messages
      pending_approval = ctx.shell_state.agent.pending_approval
      gui_messages = build_gui_messages(messages_with_ids, styled_cache, pending_approval)

      view = ctx.agent_ui.view
      help_visible = view.help_visible

      help_groups =
        if help_visible do
          Minga.Keymap.Scope.Agent.help_groups(view.focus)
        else
          []
        end

      {cursor_line, cursor_col} = UIState.input_cursor(panel)
      vim_mode = ctx.editing.mode
      inner_width = max(ctx.viewport.cols - 10, 20)
      visible_rows = PromptRenderWindow.visible_rows(panel, inner_width)
      prompt_completion = build_prompt_completion(panel)

      %{
        visible: true,
        messages: gui_messages,
        status: ctx.shell_state.agent.runtime.status || :idle,
        model: ctx.agent_ui.panel.model_name,
        thinking_level: panel.thinking_level,
        prompt: prompt_text,
        pending_approval: nil,
        help_visible: help_visible,
        help_groups: help_groups,
        prompt_line_count: UIState.input_line_count(panel),
        prompt_cursor_line: cursor_line,
        prompt_cursor_col: cursor_col,
        prompt_vim_mode: vim_mode,
        prompt_visible_rows: visible_rows,
        prompt_completion: prompt_completion
      }
    else
      %{visible: false}
    end
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
    Enum.map(messages_with_ids, &maybe_inline_approval(&1, pending_approval))
  end

  defp build_gui_messages(messages_with_ids, styled_cache, pending_approval)
       when is_list(styled_cache) do
    padded = pad_cache(styled_cache, length(messages_with_ids))

    Enum.zip(messages_with_ids, padded)
    |> Enum.map(&maybe_style_message(&1, pending_approval))
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
end
