defmodule Minga.Editor.Commands.Agent do
  @moduledoc """
  Editor commands for AI agent interaction.

  Handles toggling the agent panel, submitting prompts, scrolling
  the chat, and managing agent sessions. All functions are pure
  `state → state` transformations.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.DiffReview
  alias Minga.Agent.FileMention
  alias Minga.Agent.Markdown
  alias Minga.Agent.Message
  alias Minga.Agent.Session
  alias Minga.Agent.SessionStore
  alias Minga.Agent.SlashCommand
  alias Minga.Agent.UIState
  alias Minga.Agent.UIState.Panel
  alias Minga.Agent.View.Preview
  alias Minga.Buffer
  alias Minga.Clipboard
  alias Minga.Editor.AgentLifecycle
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.AgentSession
  alias Minga.Editor.Commands.AgentSubStates

  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Input.AgentPanel

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Legacy alias for `toggle_agent_split/1`."
  @spec toggle_agentic_view(state()) :: state()
  def toggle_agentic_view(state), do: toggle_agent_split(state)

  @doc """
  Toggles an agent chat split pane in the window tree.

  When no agent pane exists: ensures an agent session is running,
  then applies the `:agent_right` layout preset (file left, agent
  chat right). When an agent pane exists: removes it and restores
  the single-window layout.

  The agent state lives in a background agent tab (created if needed).
  """
  @spec toggle_agent_split(state()) :: state()
  def toggle_agent_split(state) do
    case EditorState.active_tab_kind(state) do
      :agent ->
        # On agent tab: switch back to most recent file tab
        case TabBar.most_recent_of_kind(EditorState.tab_bar(state), :file) do
          %Tab{id: file_id} -> EditorState.switch_tab(state, file_id)
          nil -> state
        end

      _ ->
        # On file tab: ensure agent tab exists and switch to it
        state = ensure_agent_state(state)

        case find_agent_tab(state) do
          %Tab{id: agent_id} ->
            state
            |> maybe_start_session()
            |> EditorState.switch_tab(agent_id)

          nil ->
            state
        end
    end
  end

  @spec ensure_agent_state(state()) :: state()
  defp ensure_agent_state(state) do
    agent = AgentAccess.agent(state)

    if agent.buffer == nil or not is_pid(agent.buffer) do
      ensure_agent_tab(state)
    else
      try do
        # Verify the buffer is responsive
        Buffer.buffer_name(agent.buffer)
        state
      catch
        :exit, _ -> ensure_agent_tab(state)
      end
    end
  end

  @spec ensure_agent_tab(state()) :: state()
  defp ensure_agent_tab(state) do
    case find_agent_tab(state) do
      nil ->
        state = ensure_agent_buffer(state)
        agent_buf = AgentAccess.agent(state).buffer

        # Build a windows context with an agent_chat window so the tab
        # renders through the buffer pipeline.
        win_id = 1
        rows = max(state.workspace.viewport.rows, 1)
        cols = max(state.workspace.viewport.cols, 1)
        agent_window = Window.new_agent_chat(win_id, agent_buf, rows, cols)

        windows = %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => agent_window},
          active: win_id,
          next_id: win_id + 1
        }

        # Build complete context with all @per_tab_fields populated.
        context = EditorState.build_agent_tab_defaults(state, windows, agent_buf)

        # Create agent tab in the background (don't switch to it).
        # Group creation happens later in start_agent_session when
        # the session pid is available (ensure_agent_workspace/2).
        {tb, new_tab} = TabBar.add(EditorState.tab_bar(state), :agent, "Agent")
        tb = TabBar.update_context(tb, new_tab.id, context)

        # Switch back to the original active tab
        tb = %{tb | active_id: EditorState.tab_bar(state).active_id}
        EditorState.set_tab_bar(state, tb)

      _existing ->
        state
    end
  end

  @spec ensure_agent_buffer(state()) :: state()
  defp ensure_agent_buffer(state) do
    agent = AgentAccess.agent(state)

    if is_pid(agent.buffer) do
      try do
        Buffer.buffer_name(agent.buffer)
        state
      catch
        :exit, _ -> create_agent_buffer(state)
      end
    else
      create_agent_buffer(state)
    end
  end

  @spec create_agent_buffer(state()) :: state()
  defp create_agent_buffer(state) do
    case AgentBufferSync.start_buffer() do
      buf when is_pid(buf) ->
        state = AgentAccess.update_agent(state, fn a -> %{a | buffer: buf} end)
        # Register with tree-sitter parser for markdown highlighting
        AgentLifecycle.setup_agent_highlight(state)

      _ ->
        state
    end
  end

  @doc """
  Cycles through agent tabs. If no agent tabs exist, creates one.
  Currently delegates to toggle_agent_split since there's one agent
  session. Multi-agent tab cycling is future work.
  """
  @spec cycle_agent_tabs(state()) :: state()
  def cycle_agent_tabs(state), do: toggle_agent_split(state)

  @spec find_agent_tab(state()) :: Tab.t() | nil
  defp find_agent_tab(%{shell_state: %{tab_bar: nil}}), do: nil
  defp find_agent_tab(%{shell_state: %{tab_bar: tb}}), do: TabBar.find_by_kind(tb, :agent)

  # Creates a new file tab for the active buffer and switches to it.
  # Used when deactivating the agentic view and no file tab exists yet
  # (e.g., cold boot into agent mode). The new tab starts with an empty
  @spec maybe_start_session(state()) :: state()
  defp maybe_start_session(state) do
    if AgentAccess.session(state) == nil do
      AgentSession.start_agent_session(state)
    else
      state
    end
  end

  @doc "Submits the current input text as a prompt."
  @spec submit_prompt(state()) :: state()
  def submit_prompt(state) do
    panel = AgentAccess.panel(state)

    cond do
      UIState.input_empty?(panel) ->
        state

      AgentAccess.session(state) == nil ->
        EditorState.set_status(state, "No agent session, try closing and reopening the panel")

      true ->
        text = UIState.prompt_text(panel)

        if SlashCommand.slash_command?(text) do
          state = update_agent_ui(state, &UIState.clear_input_and_scroll/1)
          execute_slash_command(state, text)
        else
          send_prompt_to_llm(state, text)
        end
    end
  end

  @spec execute_slash_command(state(), String.t()) :: state()
  defp execute_slash_command(state, text) do
    case SlashCommand.execute(state, text) do
      {:ok, state} -> state
      {:error, msg} -> EditorState.set_status(state, msg)
    end
  end

  @spec send_prompt_to_llm(state(), String.t()) :: state()
  defp send_prompt_to_llm(state, text) do
    # Resolve @file mentions before sending to the LLM.
    # Returns either a string (text only) or a list of ContentPart (when images are present).
    model = AgentAccess.panel(state).model_name

    case resolve_mentions(text, model: model) do
      {:ok, resolved} ->
        state
        |> clear_input_after_submit()
        |> deliver_prompt(resolved)

      {:error, msg} ->
        EditorState.set_status(state, msg)
    end
  catch
    # The :DOWN monitor clears stale session PIDs, but there's a race window:
    # the session can die while we're mid-call (before :DOWN is processed).
    # This is the user-facing hot path (Enter to send), so catch it here.
    :exit, _ -> EditorState.set_status(state, "Agent session crashed, SPC a n to restart")
  end

  # Clears the input and resets diff baselines after a prompt is submitted.
  @spec clear_input_after_submit(state()) :: state()
  defp clear_input_after_submit(state) do
    state = update_agent_ui(state, &UIState.clear_input_and_scroll/1)

    AgentAccess.update_agent_ui(state, fn _ ->
      UIState.clear_baselines(AgentAccess.agent_ui(state))
    end)
  end

  # Sends the resolved content to the LLM and handles steering queue feedback.
  @spec deliver_prompt(state(), String.t() | [ReqLLM.Message.ContentPart.t()]) :: state()
  defp deliver_prompt(state, resolved) do
    case Session.send_prompt(AgentAccess.session(state), resolved) do
      :ok ->
        state

      {:queued, :steering} ->
        update_agent_ui(
          state,
          &UIState.push_toast(&1, "⏳ Queued (steer). Ctrl-C to cancel.", :info)
        )

      {:error, :provider_not_ready} ->
        EditorState.set_status(state, "Agent provider still starting, try again in a moment")

      {:error, msg} when is_binary(msg) ->
        EditorState.set_status(state, msg)

      {:error, reason} ->
        EditorState.set_status(state, "Agent error: #{inspect(reason)}")
    end
  end

  @spec send_follow_up_to_llm(state(), String.t()) :: state()
  defp send_follow_up_to_llm(state, text) do
    model = AgentAccess.panel(state).model_name

    case resolve_mentions(text, model: model) do
      {:ok, resolved} ->
        state
        |> update_agent_ui(&UIState.clear_input_and_scroll/1)
        |> deliver_follow_up(resolved)

      {:error, msg} ->
        EditorState.set_status(state, msg)
    end
  catch
    :exit, _ -> EditorState.set_status(state, "Agent session crashed, SPC a n to restart")
  end

  @spec deliver_follow_up(state(), String.t() | [ReqLLM.Message.ContentPart.t()]) :: state()
  defp deliver_follow_up(state, resolved) do
    case Session.queue_follow_up(AgentAccess.session(state), resolved) do
      :ok ->
        state

      {:queued, :follow_up} ->
        update_agent_ui(
          state,
          &UIState.push_toast(&1, "⏳ Queued (follow-up). Ctrl-C to cancel.", :info)
        )

      {:error, :provider_not_ready} ->
        EditorState.set_status(state, "Agent provider still starting, try again in a moment")

      {:error, msg} when is_binary(msg) ->
        EditorState.set_status(state, msg)

      {:error, reason} ->
        EditorState.set_status(state, "Agent error: #{inspect(reason)}")
    end
  end

  @spec resolve_mentions(String.t(), keyword()) ::
          {:ok, String.t()} | {:ok, [ReqLLM.Message.ContentPart.t()]} | {:error, String.t()}
  defp resolve_mentions(text, opts) do
    root = project_root()
    FileMention.resolve_prompt(text, root, opts)
  end

  defdelegate project_root, to: Minga.Project, as: :resolve_root

  @doc "Clears the chat display without affecting conversation history."
  @spec clear_chat_display(state()) :: state()
  def clear_chat_display(state) do
    msg_count =
      if AgentAccess.session(state) do
        try do
          length(Session.messages(AgentAccess.session(state)))
        catch
          :exit, _ -> 0
        end
      else
        0
      end

    state = update_agent_ui(state, &UIState.clear_display(&1, msg_count))

    if AgentAccess.session(state) do
      Session.add_system_message(AgentAccess.session(state), "Display cleared")
    end

    state
  end

  @doc """
  Aborts the current agent operation and restores any queued messages to the prompt input.

  Queued steering and follow-up messages are recalled from the Session and placed
  back in the prompt buffer so nothing is lost.
  """
  @spec abort_agent(state()) :: state()
  def abort_agent(state) do
    case AgentAccess.session(state) do
      nil ->
        state

      session ->
        {steering, follow_up} = safe_recall_queues(session)

        try do
          Session.abort(session)
        catch
          :exit, _ -> :ok
        end

        restore_queued_to_prompt(state, steering ++ follow_up)
    end
  end

  @doc """
  Pulls all queued messages back into the prompt input without aborting the agent.

  Useful when you want to re-read or edit your queued messages. Does not stop streaming.
  """
  @spec dequeue_to_editor(state()) :: state()
  def dequeue_to_editor(state) do
    case AgentAccess.session(state) do
      nil ->
        state

      session ->
        {steering, follow_up} = safe_recall_queues(session)
        do_dequeue_to_editor(state, steering ++ follow_up)
    end
  end

  @doc "Queues the current input as a follow-up; submits normally when agent is idle."
  @spec scope_queue_follow_up(state()) :: state()
  def scope_queue_follow_up(state) do
    panel = AgentAccess.panel(state)

    cond do
      UIState.input_empty?(panel) ->
        state

      AgentAccess.session(state) == nil ->
        EditorState.set_status(state, "No agent session, try closing and reopening the panel")

      AgentAccess.agent(state).status in [:thinking, :tool_executing] ->
        text = UIState.prompt_text(panel)

        if SlashCommand.slash_command?(text) do
          state = update_agent_ui(state, &UIState.clear_input_and_scroll/1)
          execute_slash_command(state, text)
        else
          send_follow_up_to_llm(state, text)
        end

      true ->
        # Agent is idle: Ctrl+Enter behaves like regular Enter.
        submit_prompt(state)
    end
  end

  @doc "Dequeues all pending messages back into the prompt input without aborting."
  @spec scope_dequeue(state()) :: state()
  def scope_dequeue(state), do: dequeue_to_editor(state)

  @doc """
  Context-sensitive Ctrl-C handler.

  During streaming: aborts the agent and restores queued messages to the prompt.
  When idle in insert mode: returns to normal mode (vim convention).
  When idle in normal mode: no-op.
  """
  @spec scope_ctrl_c(state()) :: state()
  def scope_ctrl_c(state) do
    if AgentAccess.agent(state).status in [:thinking, :tool_executing] do
      abort_agent(state)
    else
      input_to_normal(state)
    end
  end

  @doc "Starts an agent session if one isn't already running. No-op otherwise."
  @spec ensure_agent_session(state()) :: state()
  def ensure_agent_session(state) do
    if AgentAccess.session(state) == nil do
      AgentSession.start_agent_session(state)
    else
      state
    end
  end

  @doc """
  Creates a new agent tab with a fresh session.

  If the current tab is a file tab, snapshots it and switches to a new
  agent tab. If already on an agent tab, creates a new one alongside it.
  """
  @spec new_agent_session(state()) :: state()
  def new_agent_session(state) do
    # Reset agent state for a fresh session, then start it.
    # The agent buffer is reused (content will be cleared by buffer sync).
    state =
      AgentAccess.update_agent(state, fn _a ->
        %AgentState{buffer: AgentAccess.agent(state).buffer}
      end)

    state = AgentAccess.update_agent_ui(state, fn _a -> UIState.new() end)
    AgentSession.start_agent_session(state)
  end

  @doc "Clears all saved agent sessions from disk."
  @spec clear_session_history(state()) :: state()
  def clear_session_history(state) do
    count = length(SessionStore.list())
    SessionStore.clear_all()

    msg =
      case count do
        0 -> "No saved agent sessions"
        1 -> "Cleared 1 agent session"
        n -> "Cleared #{n} agent sessions"
      end

    EditorState.set_status(state, msg)
  end

  @doc "Switches to an existing session by pid."
  @spec switch_to_session(state(), pid()) :: state()
  def switch_to_session(state, pid) when is_pid(pid) do
    current = AgentAccess.session(state)

    if pid == current do
      state
    else
      # Unsubscribe from current session if one exists
      if current do
        Session.unsubscribe(current)
      end

      # Subscribe to the target session
      Session.subscribe(pid)

      # Switch in agent state (moves current to history, target to active)
      state = update_agent(state, &AgentState.switch_session(&1, pid))

      # Update the Tab's session reference for event routing
      state =
        case state do
          %{shell_state: %{tab_bar: %TabBar{active_id: id}}} ->
            EditorState.set_tab_session(state, id, pid)

          _ ->
            state
        end

      # Reset panel scroll and auto-scroll to reflect new session's content
      AgentAccess.update_panel(state, fn p -> %{p | scroll: Minga.Editing.new_scroll()} end)
    end
  end

  @doc "Scrolls the chat panel up by half the panel height."
  @spec scroll_chat_up(state()) :: state()
  def scroll_chat_up(state) do
    if no_agent_ui?(state), do: state, else: do_scroll_chat_up(state)
  end

  defp do_scroll_chat_up(state) do
    amount = div(panel_height(state), 2)
    state = update_agent_ui(state, &UIState.scroll_up(&1, amount))
    scroll_agent_chat_window(state, -amount)
  end

  @doc "Scrolls the chat panel down by half the panel height."
  @spec scroll_chat_down(state()) :: state()
  def scroll_chat_down(state) do
    if no_agent_ui?(state), do: state, else: do_scroll_chat_down(state)
  end

  defp do_scroll_chat_down(state) do
    amount = div(panel_height(state), 2)
    state = update_agent_ui(state, &UIState.scroll_down(&1, amount))
    scroll_agent_chat_window(state, amount)
  end

  @doc "Handles a character input in the agent prompt."
  @spec input_char(state(), String.t()) :: state()
  def input_char(state, char) do
    if no_agent_ui?(state),
      do: state,
      else: update_agent_ui(state, &UIState.insert_char(&1, char))
  end

  @doc "Inserts pasted text into the agent prompt. Collapses multi-line pastes into a compact indicator."
  @spec input_paste(state(), String.t()) :: state()
  def input_paste(state, text) do
    if no_agent_ui?(state),
      do: state,
      else: update_agent_ui(state, &UIState.insert_paste(&1, text))
  end

  @doc "Toggles expand/collapse on the paste block at the cursor."
  @spec toggle_paste_expand(state()) :: state()
  def toggle_paste_expand(state) do
    update_agent_ui(state, &UIState.toggle_paste_expand/1)
  end

  @doc "Deletes the last character from the agent prompt."
  @spec input_backspace(state()) :: state()
  def input_backspace(state) do
    if no_agent_ui?(state), do: state, else: update_agent_ui(state, &UIState.delete_char/1)
  end

  @doc "Cycles the thinking level (off → low → medium → high)."
  @spec cycle_thinking_level(state()) :: state()
  def cycle_thinking_level(state) do
    if AgentAccess.session(state) == nil do
      EditorState.set_status(state, "No agent session")
    else
      case Session.cycle_thinking_level(AgentAccess.session(state)) do
        {:ok, %{"level" => level}} when is_binary(level) ->
          state = update_agent_ui(state, &UIState.set_thinking_level(&1, level))
          Session.add_system_message(AgentAccess.session(state), "Thinking: #{level}")
          EditorState.set_status(state, "Thinking: #{level}")

        {:ok, nil} ->
          EditorState.set_status(state, "Model does not support thinking levels")

        {:error, reason} ->
          EditorState.set_status(state, "Error: #{inspect(reason)}")
      end
    end
  end

  @doc "Generates a context artifact from the current session."
  @spec summarize(state()) :: state()
  def summarize(state) do
    session = AgentAccess.session(state)

    if session == nil do
      EditorState.set_status(state, "No agent session")
    else
      case Session.summarize(session) do
        {:ok, _summary, path} ->
          root = project_root()
          relative = Path.relative_to(path, root)
          EditorState.set_status(state, "Context artifact saved to #{relative}")

        {:error, reason} when is_binary(reason) ->
          EditorState.set_status(state, reason)

        {:error, reason} ->
          EditorState.set_status(state, "Error: #{inspect(reason)}")
      end
    end
  end

  @doc "Cycles to the next model in the configured rotation."
  @spec cycle_model(state()) :: state()
  def cycle_model(state) do
    if AgentAccess.session(state) == nil do
      EditorState.set_status(state, "No agent session")
    else
      case Session.cycle_model(AgentAccess.session(state)) do
        {:ok, %{"model" => model, "index" => index, "total" => total}} ->
          state = update_agent_ui(state, &UIState.set_model_name(&1, model))

          Session.add_system_message(
            AgentAccess.session(state),
            "Model: #{model} [#{index}/#{total}]"
          )

          EditorState.set_status(state, "Model: #{model} [#{index}/#{total}]")

        {:error, reason} when is_binary(reason) ->
          EditorState.set_status(state, reason)

        {:error, reason} ->
          EditorState.set_status(state, "Error: #{inspect(reason)}")
      end
    end
  end

  @doc "Sets the agent provider and restarts the session."
  @spec set_provider(state(), String.t()) :: state()
  def set_provider(state, provider) do
    state = update_agent_ui(state, &UIState.set_provider_name(&1, provider))
    AgentSession.restart_session(state, "Provider: #{provider}")
  end

  @doc "Sets the agent model without resetting conversation context."
  @spec set_model(state(), String.t()) :: state()
  def set_model(state, model) do
    state = update_agent_ui(state, &UIState.set_model_name(&1, model))

    if AgentAccess.session(state) do
      Session.set_model(AgentAccess.session(state), model)
      Session.add_system_message(AgentAccess.session(state), "Model: #{model}")
    end

    EditorState.set_status(state, "Model: #{model}")
  end

  # ── Scope commands (keymap scope dispatch) ──────────────────────────────────
  #
  # These commands are bound in Keymap.Scope.Agent and dispatched through the
  # scope resolution system. Focus-aware commands check state.workspace.agent_ui.focus to
  # route to the correct panel (chat vs file viewer).

  # ── Fold / Collapse ────────────────────────────────────────────────────────

  @doc "Toggles collapse at cursor (currently toggles all)."
  @spec scope_toggle_collapse(state()) :: state()
  def scope_toggle_collapse(state), do: toggle_all_collapses(state)

  @doc "Toggles ALL collapses."
  @spec scope_toggle_all_collapse(state()) :: state()
  def scope_toggle_all_collapse(state), do: toggle_all_collapses(state)

  @doc "Expands at cursor (stubbed, toggles all for now)."
  @spec scope_expand_at_cursor(state()) :: state()
  def scope_expand_at_cursor(state), do: state

  @doc "Collapses at cursor (stubbed, toggles all for now)."
  @spec scope_collapse_at_cursor(state()) :: state()
  def scope_collapse_at_cursor(state), do: state

  @doc "Collapses all thinking/tool blocks."
  @spec scope_collapse_all(state()) :: state()
  def scope_collapse_all(state), do: toggle_all_collapses(state)

  @doc "Expands all thinking/tool blocks."
  @spec scope_expand_all(state()) :: state()
  def scope_expand_all(state), do: toggle_all_collapses(state)

  # ── Bracket navigation ────────────────────────────────────────────────────

  @doc "Jumps to next message (stubbed)."
  @spec scope_next_message(state()) :: state()
  def scope_next_message(state), do: state

  @doc "Jumps to next code block or diff hunk."
  @spec scope_next_code_block(state()) :: state()
  def scope_next_code_block(state) do
    case AgentAccess.view(state).preview do
      %Preview{content: {:diff, review}} ->
        update_preview(state, &Preview.update_diff(&1, fn _ -> DiffReview.next_hunk(review) end))

      _ ->
        state
    end
  end

  @doc "Jumps to next tool call (stubbed)."
  @spec scope_next_tool_call(state()) :: state()
  def scope_next_tool_call(state), do: state

  @doc "Jumps to previous message (stubbed)."
  @spec scope_prev_message(state()) :: state()
  def scope_prev_message(state), do: state

  @doc "Jumps to previous code block or diff hunk."
  @spec scope_prev_code_block(state()) :: state()
  def scope_prev_code_block(state) do
    case AgentAccess.view(state).preview do
      %Preview{content: {:diff, review}} ->
        update_preview(state, &Preview.update_diff(&1, fn _ -> DiffReview.prev_hunk(review) end))

      _ ->
        state
    end
  end

  @doc "Jumps to previous tool call (stubbed)."
  @spec scope_prev_tool_call(state()) :: state()
  def scope_prev_tool_call(state), do: state

  # ── Copy ───────────────────────────────────────────────────────────────────

  @doc "Copies the code block at the cursor to the clipboard."
  @spec scope_copy_code_block(state()) :: state()
  def scope_copy_code_block(state) do
    case scroll_context(state) do
      nil ->
        state

      {_idx, msg, line_type} ->
        text = Message.text(msg)

        if line_type == :code do
          blocks = Markdown.extract_code_blocks(text)
          content = code_block_for_scroll(state, blocks)
          copy_to_clipboard(state, content, "code block")
        else
          copy_to_clipboard(state, text, "message")
        end
    end
  end

  @doc "Copies the full message at the cursor to the clipboard."
  @spec scope_copy_message(state()) :: state()
  def scope_copy_message(state) do
    case scroll_context(state) do
      nil -> state
      {_idx, msg, _type} -> copy_to_clipboard(state, Message.text(msg), "message")
    end
  end

  # ── Open code block ────────────────────────────────────────────────────────

  @doc "Opens the code block at the cursor in an editor buffer."
  @spec scope_open_code_block(state()) :: state()
  def scope_open_code_block(state) do
    case scroll_context(state) do
      nil ->
        state

      {_idx, msg, :code} ->
        text = Message.text(msg)
        blocks = Markdown.extract_code_blocks(text)
        block = code_block_at_scroll(state, blocks)

        if block,
          do: AgentSession.open_code_block(state, block.language, block.content),
          else: state

      {_idx, _msg, _other_type} ->
        state
    end
  end

  # ── Input focus ────────────────────────────────────────────────────────────

  @doc "Focuses the input field and transitions to insert mode."
  @spec scope_focus_input(state()) :: state()
  def scope_focus_input(state) do
    state = update_agent_ui(state, &UIState.set_input_focused(&1, true))
    EditorState.transition_mode(state, :insert)
  end

  @doc "Unfocuses the input field and transitions to normal mode."
  @spec scope_unfocus_input(state()) :: state()
  def scope_unfocus_input(state) do
    state = update_agent_ui(state, &UIState.set_input_focused(&1, false))
    EditorState.transition_mode(state, :normal)
  end

  @doc "Unfocuses the input field and closes the agent split pane."
  @spec scope_unfocus_and_quit(state()) :: state()
  def scope_unfocus_and_quit(state) do
    state = update_agent_ui(state, &UIState.set_input_focused(&1, false))
    toggle_agent_split(state)
  end

  # ── Input vim mode commands ──────────────────────────────────────────────
  #
  # Vim editing (motions, operators, visual mode, counts, text objects) is
  # handled by the standard Mode FSM via dispatch_prompt_via_mode_fsm.
  # Only mode transitions that originate from scope trie bindings live here.

  @doc "Switches the input from insert to normal mode. Delegates to Mode FSM via Escape."
  @spec input_to_normal(state()) :: state()
  def input_to_normal(state) do
    # Route Escape through the prompt's Mode FSM which handles the
    # insert → normal transition, cursor clamping, etc.
    AgentPanel.dispatch_prompt_via_mode_fsm(state, 27, 0)
  end

  # ── Panel management ───────────────────────────────────────────────────────

  @doc "Grows the chat panel width."
  @spec scope_grow_panel(state()) :: state()
  def scope_grow_panel(state), do: update_agent_ui(state, &UIState.grow_chat/1)

  @doc "Shrinks the chat panel width."
  @spec scope_shrink_panel(state()) :: state()
  def scope_shrink_panel(state), do: update_agent_ui(state, &UIState.shrink_chat/1)

  @doc "Resets the panel split to the default ratio."
  @spec scope_reset_panel(state()) :: state()
  def scope_reset_panel(state), do: update_agent_ui(state, &UIState.reset_split/1)

  @doc "Switches focus between chat and file viewer panels."
  @spec scope_switch_focus(state()) :: state()
  def scope_switch_focus(state) do
    if AgentAccess.view(state).focus == :chat do
      update_agent_ui(state, &UIState.set_focus(&1, :file_viewer))
    else
      update_agent_ui(state, &UIState.set_focus(&1, :chat))
    end
  end

  # ── Search ─────────────────────────────────────────────────────────────────

  @spec scope_start_search(state()) :: state()
  defdelegate scope_start_search(state), to: AgentSubStates, as: :start_search

  @spec scope_next_search_match(state()) :: state()
  defdelegate scope_next_search_match(state), to: AgentSubStates, as: :next_match

  @spec scope_prev_search_match(state()) :: state()
  defdelegate scope_prev_search_match(state), to: AgentSubStates, as: :prev_match

  # ── Session ────────────────────────────────────────────────────────────────

  @doc "Opens the session switcher picker."
  @spec scope_session_switcher(state()) :: state()
  def scope_session_switcher(state) do
    PickerUI.open(state, Minga.UI.Picker.AgentSessionSource)
  end

  # ── Help ───────────────────────────────────────────────────────────────────

  @doc "Toggles the help overlay."
  @spec scope_toggle_help(state()) :: state()
  def scope_toggle_help(state), do: update_agent_ui(state, &UIState.toggle_help/1)

  # ── Close / dismiss ────────────────────────────────────────────────────────

  @doc "Closes the agent split pane."
  @spec scope_close(state()) :: state()
  def scope_close(state), do: toggle_agent_split(state)

  @doc "Dismisses active overlays or does nothing (ESC behavior)."
  @spec scope_dismiss_or_noop(state()) :: state()
  def scope_dismiss_or_noop(state) do
    if AgentAccess.view(state).help_visible do
      update_agent_ui(state, &UIState.dismiss_help/1)
    else
      state
    end
  end

  # ── Clear ──────────────────────────────────────────────────────────────────

  @doc "Clears the chat display without losing conversation history."
  @spec scope_clear_chat(state()) :: state()
  def scope_clear_chat(state) do
    clear_chat_display(state)
  end

  # ── Insert mode commands ───────────────────────────────────────────────────

  @doc "Submits the prompt or inserts a newline (context-dependent)."
  @spec scope_submit_or_newline(state()) :: state()
  def scope_submit_or_newline(state), do: submit_prompt(state)

  @doc """
  CUA Enter behavior: focus input if not focused, submit if focused.

  CUA mode has a single trie for all agent states (no normal/insert
  distinction). This command provides the natural Enter behavior:
  first Enter focuses the input field, subsequent Enter submits.
  """
  @spec scope_focus_or_submit(state()) :: state()
  def scope_focus_or_submit(state) do
    panel = AgentAccess.panel(state)

    if panel.input_focused do
      submit_prompt(state)
    else
      scope_focus_input(state)
    end
  end

  @doc "Inserts a newline in the input field."
  @spec scope_insert_newline(state()) :: state()
  def scope_insert_newline(state) do
    update_agent_ui(state, &UIState.insert_newline/1)
  end

  @doc "Submits if input has text, aborts if agent is active."
  @spec scope_submit_or_abort(state()) :: state()
  def scope_submit_or_abort(state) do
    if UIState.prompt_text(AgentAccess.panel(state)) != "" do
      submit_prompt(state)
    else
      abort_if_active(state)
    end
  end

  @doc "Moves cursor up in input or recalls history."
  @spec scope_input_up(state()) :: state()
  def scope_input_up(state) do
    panel = AgentAccess.panel(state)
    {line, _col} = UIState.input_cursor(panel)

    if line == 0 do
      update_agent_ui(state, &UIState.history_prev/1)
    else
      update_agent_ui(state, &UIState.move_cursor_up/1)
    end
  end

  @doc "Moves cursor down in input or advances history."
  @spec scope_input_down(state()) :: state()
  def scope_input_down(state) do
    panel = AgentAccess.panel(state)
    {line, _col} = UIState.input_cursor(panel)
    max_line = UIState.input_line_count(panel) - 1

    if line >= max_line do
      update_agent_ui(state, &UIState.history_next/1)
    else
      update_agent_ui(state, &UIState.move_cursor_down/1)
    end
  end

  @doc "Self-insert: adds a character to the input field."
  @spec scope_self_insert(state(), String.t()) :: state()
  def scope_self_insert(state, char) do
    input_char(state, char)
  end

  @doc "Saves the active buffer (Ctrl+S from agent insert mode)."
  @spec scope_save_buffer(state()) :: state()
  def scope_save_buffer(state) do
    # Delegate to the standard save command
    Commands.execute(state, :save)
  end

  @doc "Aborts agent operation if one is active."
  @spec scope_abort_if_active(state()) :: state()
  def scope_abort_if_active(state) do
    if AgentAccess.agent(state).status in [:thinking, :tool_executing] do
      abort_agent(state)
    else
      state
    end
  end

  # Search input handling delegated to AgentSubStates.

  @spec handle_search_key(state(), non_neg_integer()) :: state()
  defdelegate handle_search_key(state, cp), to: AgentSubStates

  # Mention completion handling delegated to AgentSubStates.

  @spec handle_mention_key(state(), non_neg_integer(), non_neg_integer()) :: state()
  defdelegate handle_mention_key(state, cp, mods), to: AgentSubStates

  # ── Diff review commands ───────────────────────────────────────────────────

  @spec scope_accept_hunk(state()) :: state()
  defdelegate scope_accept_hunk(state), to: AgentSubStates, as: :accept_hunk

  @spec scope_reject_hunk(state()) :: state()
  defdelegate scope_reject_hunk(state), to: AgentSubStates, as: :reject_hunk

  @spec scope_accept_all_hunks(state()) :: state()
  defdelegate scope_accept_all_hunks(state), to: AgentSubStates, as: :accept_all_hunks

  @spec scope_reject_all_hunks(state()) :: state()
  defdelegate scope_reject_all_hunks(state), to: AgentSubStates, as: :reject_all_hunks

  # ── Tool approval commands ─────────────────────────────────────────────────

  @spec scope_approve_tool(state()) :: state()
  defdelegate scope_approve_tool(state), to: AgentSubStates, as: :approve_tool

  @spec scope_deny_tool(state()) :: state()
  defdelegate scope_deny_tool(state), to: AgentSubStates, as: :deny_tool

  # ── @-mention trigger ─────────────────────────────────────────────────────

  @spec scope_trigger_mention(state()) :: state()
  defdelegate scope_trigger_mention(state), to: AgentSubStates, as: :trigger_mention

  @spec scope_trigger_slash_completion(state()) :: state()
  defdelegate scope_trigger_slash_completion(state),
    to: AgentSubStates,
    as: :trigger_slash_completion

  # ── Delegated to AgentSession ──────────────────────────────────────────────

  defdelegate open_code_block(state, language, content), to: AgentSession

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec safe_recall_queues(pid()) ::
          {[String.t() | [ReqLLM.Message.ContentPart.t()]],
           [String.t() | [ReqLLM.Message.ContentPart.t()]]}
  defp safe_recall_queues(session) do
    Session.recall_queues(session)
  catch
    :exit, _ -> {[], []}
  end

  @spec restore_queued_to_prompt(state(), [String.t() | [ReqLLM.Message.ContentPart.t()]]) ::
          state()
  defp restore_queued_to_prompt(state, []), do: state

  defp restore_queued_to_prompt(state, all_queued) do
    current_text = UIState.prompt_text(AgentAccess.panel(state))
    combined = Session.combine_queue_entries_to_text(all_queued)

    restored =
      if current_text != "",
        do: combined <> "\n\n" <> current_text,
        else: combined

    update_agent_ui(state, &UIState.set_prompt_text(&1, restored))
  end

  @spec do_dequeue_to_editor(state(), [String.t() | [ReqLLM.Message.ContentPart.t()]]) ::
          state()
  defp do_dequeue_to_editor(state, []), do: EditorState.set_status(state, "No queued messages")

  defp do_dequeue_to_editor(state, all_queued) do
    count = length(all_queued)
    label = if count == 1, do: "message", else: "messages"
    state = restore_queued_to_prompt(state, all_queued)
    EditorState.set_status(state, "Restored #{count} queued #{label} to editor")
  end

  # Returns true when no agent UI is visible (panel or agent tab active),
  # meaning agent input/scroll commands should be no-ops.
  @spec no_agent_ui?(state()) :: boolean()
  defp no_agent_ui?(state) do
    not AgentAccess.panel(state).visible and EditorState.active_tab_kind(state) != :agent
  end

  @spec update_agent(state(), (AgentState.t() -> AgentState.t())) :: state()
  defp update_agent(state, fun), do: AgentAccess.update_agent(state, fun)

  @spec update_agent_ui(state(), (UIState.t() -> UIState.t())) :: state()
  defp update_agent_ui(state, fun), do: AgentAccess.update_agent_ui(state, fun)

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    AgentAccess.update_agent_ui(state, &UIState.update_preview(&1, fun))
  end

  @spec panel_height(state()) :: non_neg_integer()
  defp panel_height(state) do
    div(state.workspace.viewport.rows * 35, 100)
  end

  @spec abort_if_active(state()) :: state()
  defp abort_if_active(state) do
    if AgentAccess.agent(state).status in [:thinking, :tool_executing] do
      abort_agent(state)
    else
      state
    end
  end

  @spec toggle_all_collapses(state()) :: state()
  defp toggle_all_collapses(state) do
    if AgentAccess.session(state) do
      Session.toggle_all_tool_collapses(AgentAccess.session(state))
    end

    state
  end

  @spec scroll_context(state()) ::
          {non_neg_integer(), Message.t(), AgentBufferSync.line_type()} | nil
  defp scroll_context(state) do
    session = AgentAccess.session(state)
    panel = AgentAccess.panel(state)

    if session do
      messages = safe_messages(session)

      # Use the cached line index from sync, falling back to recompute
      line_map = cached_or_compute_line_index(panel, messages)

      # panel.scroll.offset is synced to the buffer cursor line by
      # AgentNav.sync_scroll_to_cursor, so it maps directly to
      # buffer line numbers.
      total = length(line_map)
      target = Minga.Editing.resolve_scroll(panel.scroll, total, 1)

      case Enum.at(line_map, target) do
        {msg_idx, line_type} -> {msg_idx, Enum.at(messages, msg_idx), line_type}
        nil -> nil
      end
    else
      nil
    end
  end

  @spec copy_to_clipboard(state(), String.t(), String.t()) :: state()
  defp copy_to_clipboard(state, text, label) do
    case Clipboard.write(text) do
      :ok ->
        if AgentAccess.session(state) do
          Session.add_system_message(AgentAccess.session(state), "Copied #{label} to clipboard")
        end

        update_agent_ui(state, &UIState.push_toast(&1, "Copied #{label}", :info))

      _error ->
        if AgentAccess.session(state) do
          Session.add_system_message(AgentAccess.session(state), "Clipboard write failed", :error)
        end

        update_agent_ui(state, &UIState.push_toast(&1, "Clipboard write failed", :error))
    end

    state
  end

  @spec code_block_for_scroll(state(), [Markdown.code_block()]) :: String.t()
  defp code_block_for_scroll(_state, []), do: ""

  defp code_block_for_scroll(state, blocks) do
    idx = code_block_index_for_scroll(state, blocks)
    Enum.at(blocks, idx, hd(blocks)).content
  end

  @spec code_block_at_scroll(state(), [Markdown.code_block()]) :: Markdown.code_block() | nil
  defp code_block_at_scroll(_state, []), do: nil

  defp code_block_at_scroll(state, blocks) do
    index = code_block_index_for_scroll(state, blocks)
    Enum.at(blocks, index)
  end

  @spec code_block_index_for_scroll(state(), [Markdown.code_block()]) :: non_neg_integer()
  defp code_block_index_for_scroll(state, blocks) do
    session = AgentAccess.session(state)
    panel = AgentAccess.panel(state)
    messages = safe_messages(session)

    line_map = cached_or_compute_line_index(panel, messages)

    total = length(line_map)
    target = Minga.Editing.resolve_scroll(panel.scroll, total, 1)

    {msg_idx, _type} =
      case Enum.at(line_map, target) do
        nil -> {0, :text}
        entry -> entry
      end

    msg_start =
      Enum.find_index(line_map, fn {idx, _} -> idx == msg_idx end) || 0

    lines_for_msg =
      line_map
      |> Enum.drop(msg_start)
      |> Enum.take_while(fn {idx, _} -> idx == msg_idx end)

    relative = target - msg_start
    idx = count_code_block_at(lines_for_msg, relative)
    min(idx, length(blocks) - 1)
  end

  @spec count_code_block_at(
          [{non_neg_integer(), AgentBufferSync.line_type()}],
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp count_code_block_at(lines, target_offset) do
    lines
    |> Enum.take(target_offset + 1)
    |> Enum.reduce({0, false}, fn {_idx, type}, {block_count, in_code} ->
      case {type, in_code} do
        {:code, false} -> {block_count, true}
        {:code, true} -> {block_count, true}
        {_, true} -> {block_count + 1, false}
        {_, false} -> {block_count, false}
      end
    end)
    |> elem(0)
  end

  @spec safe_messages(pid()) :: [Message.t()]
  defp safe_messages(session) do
    Session.messages(session)
  catch
    :exit, _ -> []
  end

  # Returns the cached line index from the panel state if available,
  # otherwise recomputes from messages. The cache is populated by
  # sync_buffer in AgentLifecycle on every message update.
  @spec cached_or_compute_line_index(Panel.t(), [Message.t()]) ::
          [{non_neg_integer(), AgentBufferSync.line_type()}]
  defp cached_or_compute_line_index(panel, messages) do
    case panel.cached_line_index do
      [] -> AgentBufferSync.line_message_index(messages)
      cached -> cached
    end
  end

  # Delegates to EditorState shared helper.
  defp scroll_agent_chat_window(state, delta),
    do: EditorState.scroll_agent_chat_window(state, delta)

  # Maps command name atoms to their implementing function names.
  # All agent commands work without a buffer.
  @agent_command_specs [
    {:toggle_agentic_view, "Toggle agent split pane", :toggle_agentic_view},
    {:toggle_agent_split, "Toggle agent split", :toggle_agent_split},
    {:cycle_agent_tabs, "Cycle agent tabs (opens split if none)", :cycle_agent_tabs},
    {:agent_abort, "Stop AI agent", :abort_agent},
    {:agent_new_session, "New AI agent session", :new_agent_session},
    {:agent_cycle_model, "Cycle AI agent model", :cycle_model},
    {:agent_summarize, "Summarize session to context artifact", :summarize},
    {:agent_cycle_thinking, "Cycle AI thinking level", :cycle_thinking_level},
    {:agent_scroll_half_down, "Scroll agent chat down", :scroll_chat_down},
    {:agent_scroll_half_up, "Scroll agent chat up", :scroll_chat_up},
    {:agent_toggle_collapse, "Toggle collapse at cursor", :scope_toggle_collapse},
    {:agent_toggle_all_collapse, "Toggle collapse all", :scope_toggle_all_collapse},
    {:agent_expand_at_cursor, "Expand at cursor", :scope_expand_at_cursor},
    {:agent_collapse_at_cursor, "Collapse at cursor", :scope_collapse_at_cursor},
    {:agent_collapse_all, "Collapse all", :scope_collapse_all},
    {:agent_expand_all, "Expand all", :scope_expand_all},
    {:agent_next_message, "Next message", :scope_next_message},
    {:agent_next_code_block, "Next code block", :scope_next_code_block},
    {:agent_next_tool_call, "Next tool call", :scope_next_tool_call},
    {:agent_prev_message, "Previous message", :scope_prev_message},
    {:agent_prev_code_block, "Previous code block", :scope_prev_code_block},
    {:agent_prev_tool_call, "Previous tool call", :scope_prev_tool_call},
    {:agent_copy_code_block, "Copy code block", :scope_copy_code_block},
    {:agent_copy_message, "Copy message", :scope_copy_message},
    {:agent_open_code_block, "Open code block", :scope_open_code_block},
    {:agent_focus_input, "Focus agent input", :scope_focus_input},
    {:agent_focus_or_submit, "Focus input or submit", :scope_focus_or_submit},
    {:agent_unfocus_input, "Unfocus agent input", :scope_unfocus_input},
    {:agent_unfocus_and_quit, "Unfocus input and quit", :scope_unfocus_and_quit},
    {:agent_grow_panel, "Grow agent panel", :scope_grow_panel},
    {:agent_shrink_panel, "Shrink agent panel", :scope_shrink_panel},
    {:agent_reset_panel, "Reset agent panel size", :scope_reset_panel},
    {:agent_switch_focus, "Switch agent focus", :scope_switch_focus},
    {:agent_start_search, "Start agent search", :scope_start_search},
    {:agent_next_search_match, "Next agent search match", :scope_next_search_match},
    {:agent_prev_search_match, "Previous agent search match", :scope_prev_search_match},
    {:agent_session_switcher, "Agent session switcher", :scope_session_switcher},
    {:agent_toggle_help, "Toggle agent help", :scope_toggle_help},
    {:agent_close, "Close agent panel", :scope_close},
    {:agent_dismiss_or_noop, "Dismiss agent or no-op", :scope_dismiss_or_noop},
    {:agent_clear_history, "Clear all saved agent sessions", :clear_session_history},
    {:agent_clear_chat, "Clear agent chat", :scope_clear_chat},
    {:agent_submit_or_newline, "Submit or newline", :scope_submit_or_newline},
    {:agent_insert_newline, "Insert newline in agent input", :scope_insert_newline},
    {:agent_submit_or_abort, "Submit or abort agent", :scope_submit_or_abort},
    {:agent_ctrl_c, "Abort (streaming) or normal mode (idle)", :scope_ctrl_c},
    {:agent_queue_follow_up, "Queue as follow-up or submit if idle", :scope_queue_follow_up},
    {:agent_dequeue, "Dequeue messages back to editor", :scope_dequeue},
    {:agent_input_backspace, "Agent input backspace", :input_backspace},
    {:agent_input_up, "Agent input up", :scope_input_up},
    {:agent_input_down, "Agent input down", :scope_input_down},
    {:agent_save_buffer, "Save buffer from agent", :scope_save_buffer},
    {:agent_input_to_normal, "Agent input to normal mode", :input_to_normal},
    {:agent_accept_hunk, "Accept agent hunk", :scope_accept_hunk},
    {:agent_reject_hunk, "Reject agent hunk", :scope_reject_hunk},
    {:agent_accept_all_hunks, "Accept all agent hunks", :scope_accept_all_hunks},
    {:agent_reject_all_hunks, "Reject all agent hunks", :scope_reject_all_hunks},
    {:agent_approve_tool, "Approve agent tool", :scope_approve_tool},
    {:agent_deny_tool, "Deny agent tool", :scope_deny_tool},
    {:agent_trigger_mention, "Trigger agent mention", :scope_trigger_mention}
  ]

  @impl Minga.Command.Provider
  def __commands__ do
    dispatched =
      Enum.map(@agent_command_specs, fn {cmd_name, desc, fun_name} ->
        %Minga.Command{
          name: cmd_name,
          description: desc,
          requires_buffer: false,
          execute: fn state -> apply(__MODULE__, fun_name, [state]) end
        }
      end)

    pickers = [
      %Minga.Command{
        name: :agent_pick_model,
        description: "Pick AI agent model",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.UI.Picker.AgentModelSource) end
      },
      %Minga.Command{
        name: :agent_session_history,
        description: "Agent session history",
        requires_buffer: false,
        execute: fn state -> PickerUI.open(state, Minga.UI.Picker.SessionHistorySource) end
      }
    ]

    dispatched ++ pickers
  end
end
