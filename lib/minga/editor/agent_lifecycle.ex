defmodule Minga.Editor.AgentLifecycle do
  @moduledoc """
  Agent session lifecycle helpers for the Editor GenServer.

  Handles agent session startup, auto-context loading, agent buffer
  synchronization, and tab label updates. These are called by the
  Editor during init, file open, and surface effect processing.

  All functions are pure state transformations (state -> state) that
  the Editor calls at the appropriate lifecycle points.
  """

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.MarkdownHighlight
  alias Minga.Agent.Session, as: AgentSession
  alias Minga.Agent.UIState
  alias Minga.Agent.View.Preview
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options, as: ConfigOptions
  alias Minga.Editor.Commands
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  @type state :: EditorState.t()

  # Maximum characters of tool call result to send for styled rendering.
  # Matches the truncation in AgentBufferSync.message_to_markdown/1.
  @max_styled_result_chars 500

  @doc """
  Starts the agent session if the agent pane is visible during init.

  Also loads auto-context if configured. Called once the port is ready.
  """
  @spec maybe_start_session(state()) :: state()
  def maybe_start_session(state) do
    agent = AgentAccess.agent(state)

    if agent.session == nil and LayoutPreset.has_agent_chat?(state) do
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
    auto_context = ConfigOptions.get(:agent_auto_context)
    agent_visible = LayoutPreset.has_agent_chat?(state)
    preview_empty = AgentAccess.view(state).preview.content == :empty

    if agent_visible and preview_empty and auto_context and not cli_flags.no_context do
      content = BufferServer.content(buffer_pid)
      update_preview(state, &Preview.set_file(&1, file_path, content))
    else
      state
    end
  end

  @doc """
  Registers the agent buffer with the tree-sitter parser for markdown highlighting.

  Call once after the agent buffer is created. Sets up the language and
  triggers an initial parse so highlights are ready when the buffer is viewed.
  """
  @spec setup_agent_highlight(state()) :: state()
  def setup_agent_highlight(%EditorState{} = state) do
    agent = AgentAccess.agent(state)

    if is_pid(agent.buffer) do
      # Use a custom syntax theme that dims markdown delimiters via
      # tree-sitter captures instead of regex-based ChatDecorations.
      agent_syntax = Minga.Theme.agent_syntax(state.theme)
      HighlightSync.setup_for_buffer_pid(state, agent.buffer, syntax: agent_syntax)
    else
      state
    end
  end

  @doc """
  Syncs the agent buffer content with the current session messages.

  Called as a surface effect when the agent view receives new messages.
  """
  @spec sync_buffer(state()) :: state()
  def sync_buffer(state) do
    agent = AgentAccess.agent(state)

    if is_pid(agent.buffer) and is_pid(agent.session) do
      messages =
        try do
          AgentSession.messages(agent.session)
        catch
          :exit, _ -> []
        end

      # Don't clear the buffer when the session is dead and returns no messages.
      # The buffer should preserve its last-known content.
      sync_buffer_content(state, agent.buffer, messages)
    else
      state
    end
  end

  @spec sync_buffer_content(state(), pid(), [term()]) :: state()
  defp sync_buffer_content(state, _buffer, []), do: state

  defp sync_buffer_content(state, buffer, messages) do
    # Pass pending_approval to the sync pipeline so ChatDecorations can
    # render an approval prompt on the matching tool call.
    agent = AgentAccess.agent(state)

    sync_opts =
      if agent.pending_approval, do: [pending_approval: agent.pending_approval], else: []

    line_index = AgentBufferSync.sync(buffer, messages, sync_opts)

    # Compute styled runs for GUI rendering. Use tree-sitter highlights
    # if available, otherwise fall back to regex-based markdown parser.
    # Tree-sitter highlights arrive async, so the first call typically
    # uses the fallback. When highlights land, update_styled_cache/1
    # re-caches with full tree-sitter quality.
    styled = compute_styled_messages(state, buffer, messages)

    # Cache the line index and styled messages in the UI state so
    # callers can read them without recomputing.
    state =
      AgentAccess.update_panel(state, fn p ->
        %{p | cached_line_index: line_index, cached_styled_messages: styled}
      end)

    # Trigger tree-sitter reparse for markdown highlighting.
    # replace_content_force clears edit deltas, so we do a full reparse.
    HighlightSync.request_reparse_buffer(state, buffer)
  end

  @doc """
  Updates the active agent tab's label to the first user prompt (truncated).

  Only updates if the current label is the default "New Agent" or "minga".
  """
  @spec maybe_update_tab_label(state()) :: state()
  def maybe_update_tab_label(%{tab_bar: %{active_id: active_id} = tb} = state) do
    session = AgentAccess.session(state)

    with true <- is_pid(session),
         %{kind: :agent, label: label} when is_binary(label) <- TabBar.active(tb),
         true <- default_agent_label?(label) do
      update_tab_from_session(state, tb, active_id, session)
    else
      _ -> state
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec maybe_load_auto_context(state(), Minga.CLI.flags()) :: state()
  defp maybe_load_auto_context(state, %{no_context: true}), do: state

  defp maybe_load_auto_context(state, _flags) do
    auto_context = ConfigOptions.get(:agent_auto_context)
    active_buf = state.workspace.buffers.active

    if auto_context and active_buf do
      load_buffer_as_preview(state, active_buf)
    else
      state
    end
  end

  @spec load_buffer_as_preview(state(), pid()) :: state()
  defp load_buffer_as_preview(state, buffer_pid) do
    case BufferServer.file_path(buffer_pid) do
      nil ->
        state

      path ->
        content = BufferServer.content(buffer_pid)
        update_preview(state, &Preview.set_file(&1, path, content))
    end
  end

  @spec update_tab_from_session(state(), TabBar.t(), Tab.id(), pid()) :: state()
  defp update_tab_from_session(state, tb, active_id, session) do
    # Session may be dead before :DOWN is processed (same race as sync_buffer).
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
        %{state | tab_bar: TabBar.update_label(tb, active_id, label)}
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
  Re-computes cached styled messages when tree-sitter highlights update
  for the agent buffer. Called from the Editor's highlight_spans handler
  when new spans arrive for the `*Agent*` buffer.
  """
  @spec update_styled_cache(state()) :: state()
  def update_styled_cache(state) do
    agent = AgentAccess.agent(state)

    with true <- is_pid(agent.buffer) and is_pid(agent.session),
         messages when messages != [] <- safe_messages(agent.session) do
      styled = compute_styled_messages(state, agent.buffer, messages)

      AgentAccess.update_panel(state, fn p ->
        %{p | cached_styled_messages: styled}
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

  # Computes styled runs for each message. Assistant messages and tool call
  # results get tree-sitter/markdown styling; other message types pass through as nil.
  #
  # Computes per-message byte offsets into the full buffer so tree-sitter
  # highlights (which reference the full buffer) align correctly with
  # per-message line content.
  @spec compute_styled_messages(state(), pid(), [term()]) :: [
          MarkdownHighlight.styled_lines() | nil
        ]
  defp compute_styled_messages(state, buffer, messages) do
    highlight = Map.get(state.workspace.highlight.highlights, buffer)
    theme_syntax = state.theme.syntax

    # Get the full buffer text and per-message line offsets so we can
    # compute each message's byte offset within the buffer.
    {full_text, line_offsets} = AgentBufferSync.messages_to_markdown_with_offsets(messages)
    full_lines = String.split(full_text, "\n")
    byte_offset_map = message_byte_offsets(line_offsets, full_lines)

    messages
    |> Enum.with_index()
    |> Enum.map(fn
      {{:assistant, text}, idx} ->
        byte_offset = Map.get(byte_offset_map, idx, 0)
        MarkdownHighlight.stylize(text, highlight, theme_syntax, byte_offset)

      {{:tool_call, %Minga.Agent.ToolCall{result: result}}, idx}
      when is_binary(result) and result != "" ->
        byte_offset = Map.get(byte_offset_map, idx, 0)
        # Tool call results use the same markdown/tree-sitter styling pipeline
        text = String.slice(result, 0, @max_styled_result_chars)
        MarkdownHighlight.stylize(text, highlight, theme_syntax, byte_offset)

      _ ->
        nil
    end)
  end

  # Computes the byte offset of each message's start line within the full buffer text.
  @spec message_byte_offsets(
          [Minga.Agent.ChatDecorations.line_offset()],
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
end
