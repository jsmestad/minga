defmodule MingaEditor.AgentLifecycle do
  @moduledoc """
  Agent session lifecycle helpers for the Editor GenServer.

  Handles agent session startup, auto-context loading, semantic transcript
  caching, and tab label updates. These are called by the
  Editor during init, file open, and surface effect processing.

  All functions are pure state transformations (state -> state) that
  the Editor calls at the appropriate lifecycle points.
  """

  alias MingaEditor.Agent.MarkdownHighlight
  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState.Panel
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Session, as: AgentSession
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias Minga.Buffer
  alias Minga.Config
  alias MingaEditor.Commands
  alias MingaEditor.LayoutPreset
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.UI.Highlight
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  @type state :: EditorState.t()

  # Maximum characters of tool call result to send for styled rendering.
  # Matches the truncation in Transcript.message_to_markdown/1.
  @max_styled_result_chars 500

  @doc """
  Starts the agent session if the agent pane is visible during init.

  Also loads auto-context if configured. Called once the port is ready.
  """
  @spec maybe_start_session(state()) :: state()
  def maybe_start_session(state) do
    if AgentAccess.session(state) == nil and LayoutPreset.has_agent_chat?(state) do
      state = Commands.Agent.ensure_agent_session(state)
      cli_flags = Minga.CLI.startup_flags()
      maybe_load_auto_context(state, cli_flags)
    else
      state
    end
  rescue
    e ->
      Minga.Log.warning(:agent, "Failed to start agent session at boot: #{Exception.message(e)}")
      state
  end

  @doc """
  Sets a file's content as the agentic preview pane if the agent pane
  is active and the preview is empty. Called when a file is opened while
  the agent view is already active.
  """
  @spec maybe_set_auto_context(state(), String.t(), pid()) :: state()
  def maybe_set_auto_context(state, file_path, buffer_pid) do
    cli_flags = Minga.CLI.startup_flags()
    auto_context = Config.get(:agent_auto_context)
    agent_visible = LayoutPreset.has_agent_chat?(state)
    preview_empty = AgentAccess.view(state).preview.content == :empty

    if agent_visible and preview_empty and auto_context and not cli_flags.no_context do
      content = Buffer.content(buffer_pid)
      update_preview(state, &Preview.set_file(&1, file_path, content))
    else
      state
    end
  end

  @doc """
  Legacy hook retained for callers from the former transcript-buffer path.

  The agent transcript is now semantic-only, so there is no buffer to register here.
  """
  @spec setup_agent_highlight(state()) :: state()
  def setup_agent_highlight(%EditorState{} = state), do: state

  @doc """
  Caches the semantic agent transcript metadata for the current session messages.

  Called as a surface effect when the agent view receives new messages.
  """
  @spec sync_transcript(state()) :: state()
  def sync_transcript(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      case safe_session_messages(session) do
        {:ok, messages} -> cache_transcript(state, messages)
        :dead_session -> state
      end
    else
      state
    end
  end

  @doc "Caches semantic transcript metadata for an explicit message list."
  @spec cache_messages(state(), [term()]) :: state()
  def cache_messages(state, []), do: clear_transcript_cache(state)

  def cache_messages(state, messages) when is_list(messages) do
    cache_transcript(state, messages)
  end

  @spec safe_session_messages(pid()) :: {:ok, [term()]} | :dead_session
  defp safe_session_messages(session) do
    {:ok, AgentSession.messages(session)}
  catch
    :exit, _ -> :dead_session
  end

  @spec cache_transcript(state(), [term()]) :: state()
  defp cache_transcript(state, []) do
    cache_empty_transcript(state, first_run_empty_state(state, []))
  end

  defp cache_transcript(state, messages) do
    cache_display_transcript(state, messages, first_run_empty_state(state, messages))
  end

  @spec cache_display_transcript(state(), [term()], Transcript.empty_state()) :: state()
  defp cache_display_transcript(state, messages, empty_state) do
    panel = AgentAccess.panel(state)
    jump = panel.provenance_jump

    sync_opts = add_session_display_opts([], AgentAccess.session(state))
    sync_opts = maybe_put_empty_state(sync_opts, empty_state)

    # A pending provenance jump may need an older, paged-out turn revealed so it
    # can be landed on. Otherwise keep the panel's current display window.
    display_start = jump_display_start(jump, panel.display_start_index, sync_opts[:message_ids])

    sync_opts =
      if display_start > 0,
        do: Keyword.put(sync_opts, :display_start_index, display_start),
        else: sync_opts

    result = Transcript.display(messages, sync_opts)

    # Compute styled runs for GUI rendering against the displayed transcript.
    # Reuse unchanged entries so streaming deltas restyle only the message that
    # actually changed instead of reprocessing the whole visible transcript.
    styled =
      compute_styled_messages(
        state,
        result.display_messages,
        panel.cached_display_messages,
        panel.cached_styled_messages || []
      )

    styled_assistant_count =
      Enum.count(styled, fn
        nil -> false
        _ -> true
      end)

    Minga.Log.debug(
      :agent,
      "[sync] styled cache: #{length(styled)} entries, #{styled_assistant_count} with content (#{length(messages)} messages)"
    )

    # Cache the line index and styled messages in the UI state so
    # callers can read them without recomputing. Persist the (possibly lowered)
    # display window and mark the jump landed so later re-syncs hold position
    # instead of re-pinning to the bottom.
    AgentAccess.update_panel(state, fn p ->
      Panel.cache_transcript_display(p, result, styled,
        display_start_index: display_start,
        provenance_jump: advance_jump(jump)
      )
    end)
  end

  @spec cache_empty_transcript(state(), Transcript.empty_state()) :: state()
  defp cache_empty_transcript(state, nil), do: clear_transcript_cache(state)

  defp cache_empty_transcript(state, empty_state) do
    cache_display_transcript(state, [], empty_state)
  end

  @spec clear_transcript_cache(state()) :: state()
  defp clear_transcript_cache(state) do
    AgentAccess.update_panel(state, &Panel.clear_transcript_cache/1)
  end

  @spec first_run_empty_state(state(), [term()]) :: Transcript.empty_state()
  defp first_run_empty_state(state, messages) do
    if Transcript.first_run_transcript?(messages) do
      panel = AgentAccess.panel(state)
      empty_state_for_panel(panel, AgentAccess.session(state))
    end
  end

  @spec empty_state_for_panel(MingaEditor.Agent.UIState.Panel.t(), pid() | nil) ::
          Transcript.empty_state()
  defp empty_state_for_panel(panel, session) do
    empty_state_for_status(
      configured_model?(panel.model_name),
      credentials_configured?(panel, session)
    )
  end

  @spec empty_state_for_status(boolean(), boolean()) :: Transcript.empty_state()
  defp empty_state_for_status(false, _credentials_configured), do: :no_model
  defp empty_state_for_status(true, false), do: :credentials_missing
  defp empty_state_for_status(true, true), do: nil

  @spec maybe_put_empty_state(keyword(), Transcript.empty_state()) :: keyword()
  defp maybe_put_empty_state(opts, nil), do: opts
  defp maybe_put_empty_state(opts, empty_state), do: Keyword.put(opts, :empty_state, empty_state)

  @spec configured_model?(String.t()) :: boolean()
  defp configured_model?(model) when model in ["", "unknown"], do: false
  defp configured_model?(model), do: model != AgentConfig.unconfigured_model()

  @spec credentials_configured?(MingaEditor.Agent.UIState.Panel.t(), pid() | nil) :: boolean()
  defp credentials_configured?(_panel, session) when is_pid(session) do
    session
    |> AgentSession.editor_snapshot()
    |> Map.get(:credentials_configured, false)
  catch
    :exit, _ -> false
  end

  defp credentials_configured?(panel, _session), do: panel.credentials_configured

  # The display window needed to render the jump target. Reveals a paged-out
  # target turn; otherwise keeps the panel's current window.
  @spec jump_display_start(
          ProvenanceJump.t() | nil,
          non_neg_integer(),
          [{pos_integer(), term()}] | nil
        ) ::
          non_neg_integer()
  defp jump_display_start(nil, current, _pairs), do: current
  defp jump_display_start(%ProvenanceJump{landed?: true}, current, _pairs), do: current

  defp jump_display_start(%ProvenanceJump{target_message_id: id}, current, pairs) do
    case pairs && Enum.find_index(pairs, fn {mid, _msg} -> mid == id end) do
      nil -> current
      target_index -> min(current, target_index)
    end
  end

  # After the first sync that lands the jump, mark it landed so subsequent
  # syncs hold the cursor (`:keep`) rather than re-landing or re-pinning.
  @spec advance_jump(ProvenanceJump.t() | nil) :: ProvenanceJump.t() | nil
  defp advance_jump(nil), do: nil
  defp advance_jump(%ProvenanceJump{} = jump), do: ProvenanceJump.mark_landed(jump)

  @doc """
  Updates the active agent tab's label to the first user prompt (truncated).

  Only updates if the current label is the default "New Agent" or "minga".
  """
  @spec maybe_update_tab_label(state()) :: state()
  def maybe_update_tab_label(%{shell_state: %{tab_bar: %{active_id: active_id} = tb}} = state) do
    session = AgentAccess.session(state)

    with true <- is_pid(session),
         %{kind: :agent, label: label} when is_binary(label) <- TabBar.active(tb),
         true <- default_agent_label?(label) do
      update_tab_from_session(state, tb, active_id, session)
    else
      _ -> state
    end
  end

  # No tab_bar (e.g., an extension shell) — nothing to update.
  def maybe_update_tab_label(state), do: state

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec maybe_load_auto_context(state(), Minga.CLI.flags()) :: state()
  defp maybe_load_auto_context(state, %{no_context: true}), do: state

  defp maybe_load_auto_context(state, _flags) do
    auto_context = Config.get(:agent_auto_context)
    active_buf = state.workspace.buffers.active

    if auto_context and active_buf do
      load_buffer_as_preview(state, active_buf)
    else
      state
    end
  end

  @spec load_buffer_as_preview(state(), pid()) :: state()
  defp load_buffer_as_preview(state, buffer_pid) do
    case Buffer.file_path(buffer_pid) do
      nil ->
        state

      path ->
        content = Buffer.content(buffer_pid)
        update_preview(state, &Preview.set_file(&1, path, content))
    end
  end

  @spec update_tab_from_session(state(), TabBar.t(), Tab.id(), pid()) :: state()
  defp update_tab_from_session(state, tb, active_id, session) do
    # Session may be dead before :DOWN is processed (same race as sync_transcript).
    # Empty list from catch is safe here: first_user_message([]) returns nil.
    messages =
      try do
        AgentSession.messages(session)
      catch
        :exit, _ -> []
      end

    case first_user_message(messages) do
      nil ->
        state

      text ->
        label = truncate_label(text, 30)
        EditorState.set_tab_bar(state, TabBar.update_label(tb, active_id, label))
    end
  end

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    AgentAccess.update_agent_ui(state, &UIState.update_preview(&1, fun))
  end

  @spec default_agent_label?(String.t()) :: boolean()
  defp default_agent_label?("New Agent"), do: true
  defp default_agent_label?("minga"), do: true
  defp default_agent_label?(_), do: false

  @spec first_user_message([term()]) :: String.t() | nil
  defp first_user_message(messages) do
    Enum.find_value(messages, fn
      {:user, text} -> text
      {:user, text, _attachments} -> text
      _ -> nil
    end)
  end

  @spec truncate_label(String.t(), pos_integer()) :: String.t()
  defp truncate_label(text, max) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if String.length(line) > max do
      String.slice(line, 0, max - 1) <> "\u{2026}"
    else
      line
    end
  end

  # ── Styled message caching for GUI ─────────────────────────────────────────

  @doc """
  Re-computes cached styled messages for the semantic transcript.
  """
  @spec update_styled_cache(state()) :: state()
  def update_styled_cache(state) do
    session = AgentAccess.session(state)

    with true <- is_pid(session),
         messages when messages != [] <- displayed_messages_for_styling(state, session) do
      panel = AgentAccess.panel(state)

      styled =
        compute_styled_messages(
          state,
          messages,
          panel.cached_display_messages,
          panel.cached_styled_messages || []
        )

      AgentAccess.update_panel(state, fn p ->
        Panel.cache_styled_messages(p, styled)
      end)
    else
      _ -> state
    end
  end

  @spec safe_messages(pid()) :: [term()]
  defp safe_messages(session) do
    AgentSession.messages(session)
  catch
    :exit, _ -> []
  end

  @spec displayed_messages_for_styling(state(), pid()) :: [term()]
  defp displayed_messages_for_styling(state, session) do
    case AgentAccess.panel(state).cached_display_messages do
      [] -> safe_messages(session)
      messages -> messages
    end
  end

  # Computes styled runs for each message. Assistant messages and tool call results
  # get markdown styling; other message types pass through as nil.
  @spec compute_styled_messages(state(), [term()], [term()], [
          MarkdownHighlight.styled_lines() | nil
        ]) :: [
          MarkdownHighlight.styled_lines() | nil
        ]
  defp compute_styled_messages(state, messages, previous_messages, previous_styled) do
    highlight = nil
    theme_syntax = state.theme.syntax

    {full_text, line_offsets} = Transcript.messages_to_markdown_with_offsets(messages)
    full_lines = String.split(full_text, "\n")
    byte_offset_map = message_byte_offsets(line_offsets, full_lines)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, idx} ->
      case cached_styled_message(message, idx, previous_messages, previous_styled) do
        {:ok, styled} ->
          styled

        :miss ->
          style_message(message, idx, highlight, theme_syntax, byte_offset_map)
      end
    end)
  end

  @spec cached_styled_message(term(), non_neg_integer(), [term()], [
          MarkdownHighlight.styled_lines() | nil
        ]) :: {:ok, MarkdownHighlight.styled_lines() | nil} | :miss
  defp cached_styled_message(message, idx, previous_messages, previous_styled)
       when idx < length(previous_styled) do
    case {Enum.at(previous_messages, idx), Enum.at(previous_styled, idx)} do
      {^message, styled} -> {:ok, styled}
      _ -> :miss
    end
  end

  defp cached_styled_message(_message, _idx, _previous_messages, _previous_styled) do
    :miss
  end

  @spec style_message(term(), non_neg_integer(), Highlight.t() | nil, map(), %{
          non_neg_integer() => non_neg_integer()
        }) :: MarkdownHighlight.styled_lines() | nil
  defp style_message({:assistant, text}, idx, highlight, theme_syntax, byte_offset_map) do
    byte_offset = Map.get(byte_offset_map, idx, 0)
    MarkdownHighlight.stylize(text, highlight, theme_syntax, byte_offset)
  end

  defp style_message(
         {:tool_call, %MingaAgent.ToolCall{result: result}},
         idx,
         highlight,
         theme_syntax,
         byte_offset_map
       )
       when is_binary(result) and result != "" do
    byte_offset = Map.get(byte_offset_map, idx, 0)
    text = String.slice(result, 0, @max_styled_result_chars)
    MarkdownHighlight.stylize(text, highlight, theme_syntax, byte_offset)
  end

  defp style_message(_message, _idx, _highlight, _theme_syntax, _byte_offset_map) do
    nil
  end

  # Computes the byte offset of each message's start line within the full buffer text.
  @spec message_byte_offsets(
          [Transcript.line_offset()],
          [String.t()]
        ) :: %{non_neg_integer() => non_neg_integer()}
  defp message_byte_offsets(line_offsets, full_lines) do
    Map.new(line_offsets, fn {msg_idx, start_line, _count} ->
      byte_offset =
        full_lines
        |> Enum.take(start_line)
        |> Enum.reduce(0, fn line, acc -> acc + byte_size(line) + 1 end)

      {msg_idx, byte_offset}
    end)
  end

  @spec add_session_display_opts(keyword(), pid() | nil) :: keyword()
  defp add_session_display_opts(opts, session) when is_pid(session) do
    pinned = AgentSession.pinned_ids(session)
    ids = AgentSession.messages_with_ids(session)

    opts
    |> Keyword.put(:message_ids, ids)
    |> maybe_put_pinned_ids(pinned)
  catch
    :exit, _ -> opts
  end

  defp add_session_display_opts(opts, _session), do: opts

  @spec maybe_put_pinned_ids(keyword(), MapSet.t(pos_integer())) :: keyword()
  defp maybe_put_pinned_ids(opts, pinned) do
    if MapSet.size(pinned) > 0 do
      Keyword.put(opts, :pinned_ids, pinned)
    else
      opts
    end
  end
end
