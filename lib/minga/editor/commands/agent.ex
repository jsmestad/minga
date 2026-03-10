defmodule Minga.Editor.Commands.Agent do
  @moduledoc """
  Editor commands for AI agent interaction.

  Handles toggling the agent panel, submitting prompts, scrolling
  the chat, and managing agent sessions. All functions are pure
  `state → state` transformations.
  """

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.ChatRenderer
  alias Minga.Agent.ChatSearch
  alias Minga.Agent.DiffReview
  alias Minga.Agent.FileMention
  alias Minga.Agent.Markdown
  alias Minga.Agent.Message
  alias Minga.Agent.PanelState
  alias Minga.Agent.Session
  alias Minga.Agent.SlashCommand
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Clipboard
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Helpers, as: CommandHelpers
  alias Minga.Editor.Layout
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Git.Diff

  import Bitwise

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Toggles the agent chat panel."
  @spec toggle_panel(state()) :: state()
  def toggle_panel(%{agent: %{panel: %{visible: true, input_focused: false}}} = state) do
    update_agent(state, &AgentState.focus_input(&1, true))
  end

  def toggle_panel(state) do
    state = update_agent(state, &AgentState.toggle_panel/1)

    state =
      if state.agent.panel.visible and state.agent.session == nil do
        start_agent_session(state)
      else
        state
      end

    state =
      if state.agent.panel.visible do
        update_agent(state, &AgentState.focus_input(&1, true))
      else
        update_agent(state, &AgentState.focus_input(&1, false))
      end

    state
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @doc """
  Toggles the full-screen agentic view on or off.

  On activate: switches to an agent tab (creating one if none exists),
  which snapshots the current file tab's context and restores the agent
  context. On deactivate: switches back to the most recent file tab.
  """
  @spec toggle_agentic_view(state()) :: state()
  def toggle_agentic_view(%{agentic: %{active: true}} = state) do
    deactivate_agentic_view(state)
  end

  def toggle_agentic_view(%{agentic: %{active: false}} = state) do
    activate_agentic_view(state)
  end

  @spec deactivate_agentic_view(state()) :: state()
  defp deactivate_agentic_view(state) do
    # Mark the agentic view as inactive before snapshotting, so the
    # saved context reflects "agent panel not visible".
    state = %{state | agentic: %{state.agentic | active: false}}

    case find_file_tab(state) do
      nil ->
        # No file tab yet (e.g., cold boot into agent mode). Create one
        # for the scratch buffer and switch to it.
        create_and_switch_to_file_tab(state)

      file_tab ->
        EditorState.switch_tab(state, file_tab.id)
    end
  end

  @doc """
  Cycles through agent tabs. If no agent tabs exist, creates one.
  If on an agent tab, jumps to the next agent tab. If on a file tab,
  jumps to the first agent tab.
  """
  @spec cycle_agent_tabs(state()) :: state()
  def cycle_agent_tabs(state) do
    agent_tabs = TabBar.filter_by_kind(state.tab_bar, :agent)

    case agent_tabs do
      [] ->
        activate_agentic_view(state)

      _ ->
        new_tb = TabBar.next_of_kind(state.tab_bar, :agent)

        if new_tb.active_id != state.tab_bar.active_id do
          EditorState.switch_tab(state, new_tb.active_id)
        else
          state
        end
    end
  end

  @spec activate_agentic_view(state()) :: state()
  defp activate_agentic_view(state) do
    case find_agent_tab(state) do
      nil ->
        create_and_switch_to_agent_tab(state)

      agent_tab ->
        switch_to_existing_agent_tab(state, agent_tab)
    end
  end

  # Creates a new agent tab, snapshots the current file tab, and switches.
  @spec create_and_switch_to_agent_tab(state()) :: state()
  defp create_and_switch_to_agent_tab(state) do
    # 1. Snapshot the current file tab before we leave it.
    file_tab_id = state.tab_bar.active_id
    file_context = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(state.tab_bar, file_tab_id, file_context)

    # 2. Add agent tab (TabBar.add makes it active).
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent")

    # 3. Build and store the agent context.
    agent_context = new_agent_context(state)
    tb = TabBar.update_context(tb, agent_tab.id, agent_context)

    # 4. Restore agent context into the live state.
    state = %{state | tab_bar: tb}
    state = EditorState.restore_tab_context(state, agent_context)
    maybe_start_session(state)
  end

  # Switches to an existing agent tab, re-activating its agentic view.
  @spec switch_to_existing_agent_tab(state(), Tab.t()) :: state()
  defp switch_to_existing_agent_tab(state, agent_tab) do
    # The agent tab's context has agentic.active == false (set during
    # deactivation). Patch it to active before switching.
    ctx = agent_tab.context

    updated_agentic =
      Map.get(ctx, :agentic, ViewState.new())
      |> Map.put(:active, true)
      |> Map.put(:focus, :chat)

    tb =
      TabBar.update_context(state.tab_bar, agent_tab.id, Map.put(ctx, :agentic, updated_agentic))

    state = %{state | tab_bar: tb}
    state = EditorState.switch_tab(state, agent_tab.id)
    maybe_start_session(state)
  end

  @spec new_agent_context(state()) :: Tab.context()
  defp new_agent_context(state) do
    %{
      agentic: %{ViewState.new() | active: true, focus: :chat},
      windows: %Windows{},
      file_tree: FileTreeState.close(state.file_tree),
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      keymap_scope: :agent,
      agent: state.agent,
      active_buffer: state.buffers.active,
      active_buffer_index: state.buffers.active_index
    }
  end

  @spec find_file_tab(state()) :: Tab.t() | nil
  defp find_file_tab(%{tab_bar: nil}), do: nil

  defp find_file_tab(%{tab_bar: tb}) do
    TabBar.most_recent_of_kind(tb, :file) || TabBar.find_by_kind(tb, :file)
  end

  @spec find_agent_tab(state()) :: Tab.t() | nil
  defp find_agent_tab(%{tab_bar: nil}), do: nil
  defp find_agent_tab(%{tab_bar: tb}), do: TabBar.find_by_kind(tb, :agent)

  # Creates a new file tab for the active buffer and switches to it.
  # Used when deactivating the agentic view and no file tab exists yet
  # (e.g., cold boot into agent mode).
  @spec create_and_switch_to_file_tab(state()) :: state()
  defp create_and_switch_to_file_tab(state) do
    label =
      if state.buffers.active && Process.alive?(state.buffers.active) do
        CommandHelpers.buffer_display_name(state.buffers.active)
      else
        "*scratch*"
      end

    # Snapshot agent tab context before leaving.
    agent_id = state.tab_bar.active_id
    agent_ctx = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(state.tab_bar, agent_id, agent_ctx)

    # Insert file tab (without switching active_id) so switch_tab
    # performs the full snapshot/restore cycle.
    {tb, file_tab} = TabBar.insert(tb, :file, label)
    state = %{state | tab_bar: tb}
    EditorState.switch_tab(state, file_tab.id)
  end

  @spec maybe_start_session(state()) :: state()
  defp maybe_start_session(state) do
    if state.agent.session == nil do
      start_agent_session(state)
    else
      state
    end
  end

  @doc "Submits the current input text as a prompt."
  @spec submit_prompt(state()) :: state()
  def submit_prompt(%{agent: %{panel: %{input_lines: [""]}}} = state), do: state

  def submit_prompt(%{agent: %{session: nil}} = state) do
    %{state | status_msg: "No agent session, try closing and reopening the panel"}
  end

  def submit_prompt(state) do
    text = PanelState.input_text(state.agent.panel)

    if SlashCommand.slash_command?(text) do
      state = update_agent(state, &AgentState.clear_input_and_scroll/1)
      execute_slash_command(state, text)
    else
      send_prompt_to_llm(state, text)
    end
  end

  @spec execute_slash_command(state(), String.t()) :: state()
  defp execute_slash_command(state, text) do
    case SlashCommand.execute(state, text) do
      {:ok, state} -> state
      {:error, msg} -> %{state | status_msg: msg}
    end
  end

  @spec send_prompt_to_llm(state(), String.t()) :: state()
  defp send_prompt_to_llm(state, text) do
    # Resolve @file mentions before sending to the LLM
    case resolve_mentions(text) do
      {:ok, resolved_text} ->
        case Session.send_prompt(state.agent.session, resolved_text) do
          :ok ->
            state = update_agent(state, &AgentState.clear_input_and_scroll/1)
            %{state | agentic: ViewState.clear_baselines(state.agentic)}

          {:error, :provider_not_ready} ->
            %{state | status_msg: "Agent provider still starting, try again in a moment"}

          {:error, reason} ->
            %{state | status_msg: "Agent error: #{inspect(reason)}"}
        end

      {:error, msg} ->
        %{state | status_msg: msg}
    end
  end

  @spec resolve_mentions(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp resolve_mentions(text) do
    root = project_root()
    FileMention.resolve_prompt(text, root)
  end

  @spec project_root() :: String.t()
  defp project_root do
    case Minga.Project.root() do
      nil -> File.cwd!()
      root -> root
    end
  catch
    :exit, _ -> File.cwd!()
  end

  @doc "Clears the chat display without affecting conversation history."
  @spec clear_chat_display(state()) :: state()
  def clear_chat_display(state) do
    msg_count =
      if state.agent.session do
        try do
          length(Session.messages(state.agent.session))
        catch
          :exit, _ -> 0
        end
      else
        0
      end

    state = update_agent(state, &AgentState.clear_display(&1, msg_count))

    if state.agent.session do
      Session.add_system_message(state.agent.session, "Display cleared")
    end

    state
  end

  @doc "Aborts the current agent operation."
  @spec abort_agent(state()) :: state()
  def abort_agent(%{agent: %{session: nil}} = state), do: state

  def abort_agent(state) do
    Session.abort(state.agent.session)
    state
  end

  @doc "Starts an agent session if one isn't already running. No-op otherwise."
  @spec ensure_agent_session(state()) :: state()
  def ensure_agent_session(%{agent: %{session: nil}} = state) do
    start_agent_session(state)
  end

  def ensure_agent_session(state), do: state

  @doc """
  Creates a new agent tab with a fresh session.

  If the current tab is a file tab, snapshots it and switches to a new
  agent tab. If already on an agent tab, creates a new one alongside it.
  """
  @spec new_agent_session(state()) :: state()
  def new_agent_session(%{tab_bar: %TabBar{}} = state) do
    # Snapshot current tab before leaving it.
    current_id = state.tab_bar.active_id
    current_ctx = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(state.tab_bar, current_id, current_ctx)

    # Add new agent tab (becomes active).
    {tb, agent_tab} = TabBar.add(tb, :agent, "New Agent")

    # Fresh agent state for the new tab.
    agent_context = %{
      agentic: %{ViewState.new() | active: true, focus: :chat},
      windows: %Windows{},
      file_tree: FileTreeState.close(state.file_tree),
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      keymap_scope: :agent,
      agent: %AgentState{},
      active_buffer: state.buffers.active,
      active_buffer_index: state.buffers.active_index
    }

    tb = TabBar.update_context(tb, agent_tab.id, agent_context)
    state = %{state | tab_bar: tb}
    state = EditorState.restore_tab_context(state, agent_context)
    start_agent_session(state)
  end

  # Fallback for bare maps or states without a tab bar (tests, slash commands).
  def new_agent_session(state) do
    start_agent_session(state)
  end

  @doc "Switches to an existing session by pid."
  @spec switch_to_session(state(), pid()) :: state()
  def switch_to_session(%{agent: %{session: current}} = state, pid)
      when is_pid(pid) and pid == current do
    state
  end

  def switch_to_session(state, pid) when is_pid(pid) do
    # Unsubscribe from current session if one exists
    if state.agent.session do
      Session.unsubscribe(state.agent.session)
    end

    # Subscribe to the target session
    Session.subscribe(pid)

    # Switch in agent state (moves current to history, target to active)
    state = update_agent(state, &AgentState.switch_session(&1, pid))

    # Update the Tab's session reference for event routing
    state =
      case state do
        %{tab_bar: %TabBar{active_id: id}} ->
          EditorState.set_tab_session(state, id, pid)

        _ ->
          state
      end

    # Reset panel scroll and auto-scroll to reflect new session's content
    update_agent(state, fn agent ->
      panel = %{agent.panel | scroll_offset: 0, auto_scroll: true}
      %{agent | panel: panel}
    end)
  end

  @doc "Scrolls the chat panel up by half the panel height."
  @spec scroll_chat_up(state()) :: state()
  def scroll_chat_up(%{agentic: %{active: false}, agent: %{panel: %{visible: false}}} = state),
    do: state

  def scroll_chat_up(state) do
    amount = div(panel_height(state), 2)
    update_agent(state, &AgentState.scroll_up(&1, amount))
  end

  @doc "Scrolls the chat panel down by half the panel height."
  @spec scroll_chat_down(state()) :: state()
  def scroll_chat_down(%{agentic: %{active: false}, agent: %{panel: %{visible: false}}} = state),
    do: state

  def scroll_chat_down(state) do
    amount = div(panel_height(state), 2)
    update_agent(state, &AgentState.scroll_down(&1, amount))
  end

  @doc "Handles a character input in the agent prompt."
  @spec input_char(state(), String.t()) :: state()
  def input_char(%{agentic: %{active: false}, agent: %{panel: %{visible: false}}} = state, _char),
    do: state

  def input_char(state, char) do
    update_agent(state, &AgentState.insert_char(&1, char))
  end

  @doc "Deletes the last character from the agent prompt."
  @spec input_backspace(state()) :: state()
  def input_backspace(%{agentic: %{active: false}, agent: %{panel: %{visible: false}}} = state),
    do: state

  def input_backspace(state) do
    update_agent(state, &AgentState.delete_char/1)
  end

  @doc "Cycles the thinking level (off → low → medium → high)."
  @spec cycle_thinking_level(state()) :: state()
  def cycle_thinking_level(%{agent: %{session: nil}} = state) do
    %{state | status_msg: "No agent session"}
  end

  def cycle_thinking_level(state) do
    case Session.cycle_thinking_level(state.agent.session) do
      {:ok, %{"level" => level}} when is_binary(level) ->
        state = update_agent(state, &AgentState.set_thinking_level(&1, level))
        Session.add_system_message(state.agent.session, "Thinking: #{level}")
        %{state | status_msg: "Thinking: #{level}"}

      {:ok, nil} ->
        %{state | status_msg: "Model does not support thinking levels"}

      {:error, reason} ->
        %{state | status_msg: "Error: #{inspect(reason)}"}
    end
  end

  @doc "Sets the agent provider and restarts the session."
  @spec set_provider(state(), String.t()) :: state()
  def set_provider(state, provider) do
    state = update_agent(state, &AgentState.set_provider_name(&1, provider))
    restart_session(state, "Provider: #{provider}")
  end

  @doc "Sets the agent model and restarts the session."
  @spec set_model(state(), String.t()) :: state()
  def set_model(state, model) do
    state = update_agent(state, &AgentState.set_model_name(&1, model))
    restart_session(state, "Model: #{model}")
  end

  # ── Scope commands (keymap scope dispatch) ──────────────────────────────────
  #
  # These commands are bound in Keymap.Scope.Agent and dispatched through the
  # scope resolution system. Focus-aware commands check state.agentic.focus to
  # route to the correct panel (chat vs file viewer).

  # ── Navigation ─────────────────────────────────────────────────────────────

  @doc "Scrolls down 1 line in the focused panel."
  @spec scope_scroll_down(state()) :: state()
  def scope_scroll_down(%{agentic: %{focus: :file_viewer}} = state) do
    update_agentic(state, &ViewState.scroll_viewer_down(&1, 1))
  end

  def scope_scroll_down(state) do
    update_agent(state, &AgentState.scroll_down(&1, 1))
  end

  @doc "Scrolls up 1 line in the focused panel."
  @spec scope_scroll_up(state()) :: state()
  def scope_scroll_up(%{agentic: %{focus: :file_viewer}} = state) do
    update_agentic(state, &ViewState.scroll_viewer_up(&1, 1))
  end

  def scope_scroll_up(state) do
    update_agent(state, &AgentState.scroll_up(&1, 1))
  end

  @doc "Scrolls down half a page in the focused panel."
  @spec scope_scroll_half_down(state()) :: state()
  def scope_scroll_half_down(%{agentic: %{focus: :file_viewer}} = state) do
    amount = half_page(state)
    update_agentic(state, &ViewState.scroll_viewer_down(&1, amount))
  end

  def scope_scroll_half_down(state) do
    amount = half_page(state)
    update_agent(state, &AgentState.scroll_down(&1, amount))
  end

  @doc "Scrolls up half a page in the focused panel."
  @spec scope_scroll_half_up(state()) :: state()
  def scope_scroll_half_up(%{agentic: %{focus: :file_viewer}} = state) do
    amount = half_page(state)
    update_agentic(state, &ViewState.scroll_viewer_up(&1, amount))
  end

  def scope_scroll_half_up(state) do
    amount = half_page(state)
    update_agent(state, &AgentState.scroll_up(&1, amount))
  end

  @doc "Scrolls to the bottom of the focused panel."
  @spec scope_scroll_bottom(state()) :: state()
  def scope_scroll_bottom(%{agentic: %{focus: :file_viewer}} = state) do
    update_agentic(state, &ViewState.scroll_viewer_to_bottom/1)
  end

  def scope_scroll_bottom(state) do
    update_agent(state, &AgentState.scroll_to_bottom/1)
  end

  @doc "Scrolls to the top of the focused panel."
  @spec scope_scroll_top(state()) :: state()
  def scope_scroll_top(%{agentic: %{focus: :file_viewer}} = state) do
    update_agentic(state, &ViewState.scroll_viewer_to_top/1)
  end

  def scope_scroll_top(state) do
    update_agent(state, &AgentState.scroll_to_top/1)
  end

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
  def scope_next_code_block(%{agentic: %{preview: %Preview{content: {:diff, review}}}} = state) do
    update_preview(state, &Preview.update_diff(&1, fn _ -> DiffReview.next_hunk(review) end))
  end

  def scope_next_code_block(state), do: state

  @doc "Jumps to next tool call (stubbed)."
  @spec scope_next_tool_call(state()) :: state()
  def scope_next_tool_call(state), do: state

  @doc "Jumps to previous message (stubbed)."
  @spec scope_prev_message(state()) :: state()
  def scope_prev_message(state), do: state

  @doc "Jumps to previous code block or diff hunk."
  @spec scope_prev_code_block(state()) :: state()
  def scope_prev_code_block(%{agentic: %{preview: %Preview{content: {:diff, review}}}} = state) do
    update_preview(state, &Preview.update_diff(&1, fn _ -> DiffReview.prev_hunk(review) end))
  end

  def scope_prev_code_block(state), do: state

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
        if block, do: open_code_block(state, block.language, block.content), else: state

      {_idx, _msg, _other_type} ->
        state
    end
  end

  # ── Input focus ────────────────────────────────────────────────────────────

  @doc "Focuses the input field and transitions to insert mode."
  @spec scope_focus_input(state()) :: state()
  def scope_focus_input(state) do
    update_agent(state, &AgentState.focus_input(&1, true))
  end

  @doc "Unfocuses the input field and transitions to normal mode."
  @spec scope_unfocus_input(state()) :: state()
  def scope_unfocus_input(state) do
    update_agent(state, &AgentState.focus_input(&1, false))
  end

  @doc "Unfocuses the input field and closes the agentic view."
  @spec scope_unfocus_and_quit(state()) :: state()
  def scope_unfocus_and_quit(state) do
    state = update_agent(state, &AgentState.focus_input(&1, false))
    toggle_agentic_view(state)
  end

  # ── Panel management ───────────────────────────────────────────────────────

  @doc "Grows the chat panel width."
  @spec scope_grow_panel(state()) :: state()
  def scope_grow_panel(state), do: update_agentic(state, &ViewState.grow_chat/1)

  @doc "Shrinks the chat panel width."
  @spec scope_shrink_panel(state()) :: state()
  def scope_shrink_panel(state), do: update_agentic(state, &ViewState.shrink_chat/1)

  @doc "Resets the panel split to the default ratio."
  @spec scope_reset_panel(state()) :: state()
  def scope_reset_panel(state), do: update_agentic(state, &ViewState.reset_split/1)

  @doc "Switches focus between chat and file viewer panels."
  @spec scope_switch_focus(state()) :: state()
  def scope_switch_focus(%{agentic: %{focus: :chat}} = state) do
    update_agentic(state, &ViewState.set_focus(&1, :file_viewer))
  end

  def scope_switch_focus(state) do
    update_agentic(state, &ViewState.set_focus(&1, :chat))
  end

  # ── Search ─────────────────────────────────────────────────────────────────

  @doc "Starts search mode in the chat."
  @spec scope_start_search(state()) :: state()
  def scope_start_search(state) do
    scroll = state.agent.panel.scroll_offset
    update_agentic(state, &ViewState.start_search(&1, scroll))
  end

  @doc "Jumps to the next search match."
  @spec scope_next_search_match(state()) :: state()
  def scope_next_search_match(%{agentic: %{search: %{input_active: true}}} = state), do: state

  def scope_next_search_match(state) do
    state = update_agentic(state, &ViewState.next_search_match/1)
    scroll_to_current_match(state)
  end

  @doc "Jumps to the previous search match."
  @spec scope_prev_search_match(state()) :: state()
  def scope_prev_search_match(%{agentic: %{search: %{input_active: true}}} = state), do: state

  def scope_prev_search_match(state) do
    state = update_agentic(state, &ViewState.prev_search_match/1)
    scroll_to_current_match(state)
  end

  # ── Session ────────────────────────────────────────────────────────────────

  @doc "Opens the session switcher picker."
  @spec scope_session_switcher(state()) :: state()
  def scope_session_switcher(state) do
    PickerUI.open(state, Minga.Picker.AgentSessionSource)
  end

  # ── Help ───────────────────────────────────────────────────────────────────

  @doc "Toggles the help overlay."
  @spec scope_toggle_help(state()) :: state()
  def scope_toggle_help(state), do: update_agentic(state, &ViewState.toggle_help/1)

  # ── Close / dismiss ────────────────────────────────────────────────────────

  @doc "Closes the agentic view."
  @spec scope_close(state()) :: state()
  def scope_close(state), do: toggle_agentic_view(state)

  @doc "Dismisses active overlays or does nothing (ESC behavior)."
  @spec scope_dismiss_or_noop(state()) :: state()
  def scope_dismiss_or_noop(%{agentic: %{help_visible: true}} = state) do
    update_agentic(state, &ViewState.dismiss_help/1)
  end

  def scope_dismiss_or_noop(state), do: state

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

  @doc "Inserts a newline in the input field."
  @spec scope_insert_newline(state()) :: state()
  def scope_insert_newline(state) do
    update_agent(state, &AgentState.insert_newline/1)
  end

  @doc "Submits if input has text, aborts if agent is active."
  @spec scope_submit_or_abort(state()) :: state()
  def scope_submit_or_abort(state) do
    if PanelState.input_text(state.agent.panel) != "" do
      submit_prompt(state)
    else
      abort_if_active(state)
    end
  end

  @doc "Moves cursor up in input or recalls history."
  @spec scope_input_up(state()) :: state()
  def scope_input_up(state) do
    {line, _col} = state.agent.panel.input_cursor

    if line == 0 do
      update_agent(state, &AgentState.history_prev/1)
    else
      update_agent(state, &AgentState.move_cursor_up/1)
    end
  end

  @doc "Moves cursor down in input or advances history."
  @spec scope_input_down(state()) :: state()
  def scope_input_down(state) do
    {line, _col} = state.agent.panel.input_cursor
    max_line = length(state.agent.panel.input_lines) - 1

    if line >= max_line do
      update_agent(state, &AgentState.history_next/1)
    else
      update_agent(state, &AgentState.move_cursor_down/1)
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
    if state.agent.status in [:thinking, :tool_executing] do
      abort_agent(state)
    else
      state
    end
  end

  # ── Search input handling (sub-state within agent scope) ───────────────────

  @doc "Handles a key during active search input."
  @spec handle_search_key(state(), non_neg_integer()) :: state()
  def handle_search_key(state, 13) do
    # Enter: confirm search
    update_agentic(state, &ViewState.confirm_search/1)
  end

  def handle_search_key(state, 27) do
    # Escape: cancel search, restore scroll
    saved = ViewState.search_saved_scroll(state.agentic)
    state = update_agentic(state, &ViewState.cancel_search/1)
    if saved, do: update_agent(state, &AgentState.set_scroll(&1, saved)), else: state
  end

  def handle_search_key(state, 127) do
    # Backspace
    query = ViewState.search_query(state.agentic) || ""

    if query == "" do
      handle_search_key(state, 27)
    else
      new_query = String.slice(query, 0..-2//1)
      state = update_agentic(state, &ViewState.update_search_query(&1, new_query))
      run_search(state, new_query)
    end
  end

  def handle_search_key(state, cp) when cp >= 32 and cp <= 126 do
    char = <<cp::utf8>>
    query = (ViewState.search_query(state.agentic) || "") <> char
    state = update_agentic(state, &ViewState.update_search_query(&1, query))
    run_search(state, query)
  end

  def handle_search_key(state, _cp), do: state

  # ── Mention completion handling (sub-state within agent scope) ─────────────

  @doc "Handles a key during active mention completion."
  @spec handle_mention_key(state(), non_neg_integer(), non_neg_integer()) :: state()
  def handle_mention_key(state, 9, mods) do
    if band(mods, 0x01) != 0 do
      # Shift+Tab: prev candidate
      update_panel(state, fn p ->
        comp = FileMention.select_prev(p.mention_completion)
        %{p | mention_completion: comp}
      end)
    else
      # Tab: next candidate
      update_panel(state, fn p ->
        comp = FileMention.select_next(p.mention_completion)
        %{p | mention_completion: comp}
      end)
    end
  end

  def handle_mention_key(state, 13, _mods) do
    # Enter: accept selection
    accept_mention_completion(state)
  end

  def handle_mention_key(state, 27, _mods) do
    # Escape: cancel
    update_panel(state, fn p -> %{p | mention_completion: nil} end)
  end

  def handle_mention_key(state, 127, _mods) do
    # Backspace
    comp = state.agent.panel.mention_completion

    if comp.prefix == "" do
      state = input_backspace(state)
      update_panel(state, fn p -> %{p | mention_completion: nil} end)
    else
      state = input_backspace(state)
      new_prefix = String.slice(comp.prefix, 0..-2//1)

      update_panel(state, fn p ->
        %{p | mention_completion: FileMention.update_prefix(comp, new_prefix)}
      end)
    end
  end

  def handle_mention_key(state, cp, mods)
      when cp >= 32 and band(mods, 0x02) == 0 and band(mods, 0x04) == 0 do
    mention_insert_char(state, <<cp::utf8>>)
  end

  def handle_mention_key(state, _cp_with_mods, _mods) when is_map(state), do: state

  @spec mention_insert_char(state(), String.t()) :: state()
  defp mention_insert_char(state, " ") do
    state = update_panel(state, fn p -> %{p | mention_completion: nil} end)
    input_char(state, " ")
  end

  defp mention_insert_char(state, char) do
    state = input_char(state, char)
    comp = state.agent.panel.mention_completion
    new_prefix = comp.prefix <> char

    update_panel(state, fn p ->
      %{p | mention_completion: FileMention.update_prefix(comp, new_prefix)}
    end)
  end

  # ── Diff review commands ───────────────────────────────────────────────────

  @doc "Accepts the current diff hunk during review."
  @spec scope_accept_hunk(state()) :: state()
  def scope_accept_hunk(%{agentic: %{preview: %Preview{content: {:diff, _review}}}} = state) do
    state =
      update_preview(state, &Preview.update_diff(&1, fn r -> DiffReview.accept_current(r) end))

    maybe_finish_review(state)
  end

  def scope_accept_hunk(state), do: state

  @doc "Rejects the current diff hunk during review."
  @spec scope_reject_hunk(state()) :: state()
  def scope_reject_hunk(%{agentic: %{preview: %Preview{content: {:diff, review}}}} = state) do
    hunk = DiffReview.current_hunk(review)

    if hunk do
      revert_hunk_on_disk(review.path, hunk)
    end

    state =
      update_preview(state, &Preview.update_diff(&1, fn r -> DiffReview.reject_current(r) end))

    maybe_finish_review(state)
  end

  def scope_reject_hunk(state), do: state

  @doc "Accepts all remaining diff hunks."
  @spec scope_accept_all_hunks(state()) :: state()
  def scope_accept_all_hunks(%{agentic: %{preview: %Preview{content: {:diff, _}}}} = state) do
    state =
      update_preview(state, &Preview.update_diff(&1, fn r -> DiffReview.accept_all(r) end))

    maybe_finish_review(state)
  end

  def scope_accept_all_hunks(state), do: state

  @doc "Rejects all remaining diff hunks."
  @spec scope_reject_all_hunks(state()) :: state()
  def scope_reject_all_hunks(%{agentic: %{preview: %Preview{content: {:diff, review}}}} = state) do
    unresolved_hunks =
      review.hunks
      |> Enum.with_index()
      |> Enum.reject(fn {_hunk, idx} -> Map.has_key?(review.resolutions, idx) end)
      |> Enum.map(fn {hunk, _idx} -> hunk end)
      |> Enum.reverse()

    revert_hunks_on_disk(review.path, unresolved_hunks)

    state =
      update_preview(state, &Preview.update_diff(&1, fn r -> DiffReview.reject_all(r) end))

    maybe_finish_review(state)
  end

  def scope_reject_all_hunks(state), do: state

  # ── Tool approval commands ─────────────────────────────────────────────────

  @doc "Approves the pending tool execution."
  @spec scope_approve_tool(state()) :: state()
  def scope_approve_tool(%{agent: %{session: session, pending_approval: approval}} = state)
      when is_pid(session) and is_map(approval) do
    Session.respond_to_approval(session, :approve)
    update_agent(state, &AgentState.clear_pending_approval/1)
  end

  def scope_approve_tool(state), do: state

  @doc "Denies the pending tool execution."
  @spec scope_deny_tool(state()) :: state()
  def scope_deny_tool(%{agent: %{session: session, pending_approval: approval}} = state)
      when is_pid(session) and is_map(approval) do
    Session.respond_to_approval(session, :reject)
    update_agent(state, &AgentState.clear_pending_approval/1)
  end

  def scope_deny_tool(state), do: state

  # ── @-mention trigger ─────────────────────────────────────────────────────

  @doc "Triggers @-mention file completion."
  @spec scope_trigger_mention(state()) :: state()
  def scope_trigger_mention(state) do
    if should_trigger_mention?(state) do
      state = input_char(state, "@")
      start_mention_completion(state)
    else
      input_char(state, "@")
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec restart_session(state(), String.t()) :: state()
  defp restart_session(state, message) do
    if state.agent.session do
      try do
        GenServer.stop(state.agent.session, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    state = update_agent(state, &AgentState.clear_session/1)
    state = %{state | status_msg: message}
    if AgentState.visible?(state.agent), do: start_agent_session(state), else: state
  end

  @spec start_agent_session(state()) :: state()
  defp start_agent_session(state) do
    opts = [
      thinking_level: state.agent.panel.thinking_level,
      provider_opts: [
        provider: state.agent.panel.provider_name,
        model: state.agent.panel.model_name
      ]
    ]

    case start_and_subscribe(opts) do
      {:ok, pid} ->
        state =
          if state.agent.buffer == nil do
            buf = AgentBufferSync.start_buffer()
            update_agent(state, &AgentState.set_buffer(&1, buf))
          else
            state
          end

        state = update_agent(state, &AgentState.set_session(&1, pid))

        # Record the session pid on the Tab struct for event routing.
        case state do
          %{tab_bar: %TabBar{active_id: id}} ->
            EditorState.set_tab_session(state, id, pid)

          _ ->
            state
        end

      {:error, reason} ->
        require Logger
        msg = format_session_error(reason)
        Logger.error("[Agent] #{msg}")
        Minga.Editor.log_to_messages("[Agent] #{msg}")
        update_agent(state, &AgentState.set_error(&1, msg))
    end
  end

  @spec start_and_subscribe(keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_and_subscribe(opts) do
    case Minga.Agent.Supervisor.start_session(opts) do
      {:ok, pid} ->
        try do
          Session.subscribe(pid)
          {:ok, pid}
        catch
          :exit, reason ->
            # Session died before we could subscribe (e.g. provider binary missing).
            # Clean up the child so the supervisor doesn't hold a dead reference.
            Minga.Agent.Supervisor.stop_session(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Opens a code block from an agent chat message as a scratch buffer.

  Creates a new buffer with the code block content, sets its filetype
  based on the language tag, and displays it in the preview pane. The
  buffer is named `*Agent: {language}*` and is not associated with a
  file on disk.
  """
  @spec open_code_block(state(), String.t(), String.t()) :: state()
  def open_code_block(state, language, content) do
    name = buffer_name_for_language(language)
    filetype = filetype_from_language(language)

    {:ok, buf} =
      BufferServer.start_link(
        content: content,
        buffer_name: name,
        filetype: filetype
      )

    # Set as active buffer so it shows in the file viewer panel
    state = put_in(state.buffers.active, buf)

    # Show a system message about the opened block
    if state.agent.session do
      Session.add_system_message(
        state.agent.session,
        "Opened #{if(language == "", do: "text", else: language)} code block in buffer"
      )
    end

    state
  end

  @spec buffer_name_for_language(String.t()) :: String.t()
  defp buffer_name_for_language(""), do: "*Agent: text*"
  defp buffer_name_for_language(lang), do: "*Agent: #{lang}*"

  @spec filetype_from_language(String.t()) :: atom() | nil
  defp filetype_from_language(""), do: nil

  defp filetype_from_language(lang) do
    # Map common language tags to Minga filetypes
    mapping = %{
      "elixir" => :elixir,
      "ex" => :elixir,
      "exs" => :elixir,
      "javascript" => :javascript,
      "js" => :javascript,
      "typescript" => :typescript,
      "ts" => :typescript,
      "python" => :python,
      "py" => :python,
      "ruby" => :ruby,
      "rb" => :ruby,
      "rust" => :rust,
      "rs" => :rust,
      "go" => :go,
      "golang" => :go,
      "zig" => :zig,
      "c" => :c,
      "cpp" => :cpp,
      "c++" => :cpp,
      "java" => :java,
      "json" => :json,
      "yaml" => :yaml,
      "yml" => :yaml,
      "toml" => :toml,
      "html" => :html,
      "css" => :css,
      "lua" => :lua,
      "bash" => :bash,
      "sh" => :bash,
      "shell" => :bash,
      "zsh" => :bash,
      "sql" => :sql,
      "markdown" => :markdown,
      "md" => :markdown,
      "xml" => :xml,
      "dockerfile" => :dockerfile,
      "docker" => :dockerfile,
      "makefile" => :makefile,
      "make" => :makefile
    }

    Map.get(mapping, String.downcase(lang))
  end

  @spec update_agent(state(), (AgentState.t() -> AgentState.t())) :: state()
  defp update_agent(state, fun) do
    %{state | agent: fun.(state.agent)}
  end

  @spec update_agentic(state(), (ViewState.t() -> ViewState.t())) :: state()
  defp update_agentic(state, fun) do
    %{state | agentic: fun.(state.agentic)}
  end

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    %{state | agentic: ViewState.update_preview(state.agentic, fun)}
  end

  @spec update_panel(state(), (PanelState.t() -> PanelState.t())) :: state()
  defp update_panel(state, fun) do
    update_agent(state, fn agent -> %{agent | panel: fun.(agent.panel)} end)
  end

  @spec format_session_error(term()) :: String.t()
  defp format_session_error({:pi_not_found, msg}) when is_binary(msg), do: msg
  defp format_session_error({:noproc, _}), do: "Agent supervisor not running"
  defp format_session_error(reason), do: "Failed to start session: #{inspect(reason)}"

  @spec panel_height(state()) :: non_neg_integer()
  defp panel_height(state) do
    div(state.viewport.rows * 35, 100)
  end

  @spec half_page(state()) :: pos_integer()
  defp half_page(state), do: max(div(state.viewport.rows, 2), 1)

  @spec abort_if_active(state()) :: state()
  defp abort_if_active(state) do
    if state.agent.status in [:thinking, :tool_executing] do
      abort_agent(state)
    else
      state
    end
  end

  @spec toggle_all_collapses(state()) :: state()
  defp toggle_all_collapses(state) do
    if state.agent.session do
      Session.toggle_all_tool_collapses(state.agent.session)
    end

    state
  end

  @spec scroll_context(state()) ::
          {non_neg_integer(), Message.t(), ChatRenderer.line_type()} | nil
  defp scroll_context(state) do
    session = state.agent.session
    panel = state.agent.panel

    if session do
      messages = safe_messages(session)
      theme = state.theme
      width = state.viewport.cols

      line_map =
        ChatRenderer.line_message_map(messages, width, theme, panel.display_start_index)

      offset = panel.scroll_offset
      total_lines = length(line_map)
      target = max(total_lines - offset - 1, 0)

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
        if state.agent.session do
          Session.add_system_message(state.agent.session, "Copied #{label} to clipboard")
        end

        update_agentic(state, &ViewState.push_toast(&1, "Copied #{label}", :info))

      _error ->
        if state.agent.session do
          Session.add_system_message(state.agent.session, "Clipboard write failed", :error)
        end

        update_agentic(state, &ViewState.push_toast(&1, "Clipboard write failed", :error))
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
    session = state.agent.session
    panel = state.agent.panel
    messages = safe_messages(session)

    line_map =
      ChatRenderer.line_message_map(
        messages,
        state.viewport.cols,
        state.theme,
        panel.display_start_index
      )

    offset = panel.scroll_offset
    total_lines = length(line_map)
    target = max(total_lines - offset - 1, 0)

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

  @spec count_code_block_at([{non_neg_integer(), ChatRenderer.line_type()}], non_neg_integer()) ::
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

  @spec run_search(state(), String.t()) :: state()
  defp run_search(state, query) do
    messages = if state.agent.session, do: safe_messages(state.agent.session), else: []
    matches = ChatSearch.find_matches(messages, query)
    state = update_agentic(state, &ViewState.set_search_matches(&1, matches))
    if matches != [], do: scroll_to_current_match(state), else: state
  end

  @spec scroll_to_current_match(state()) :: state()
  defp scroll_to_current_match(%{agentic: %{search: nil}} = state), do: state

  defp scroll_to_current_match(%{agentic: %{search: search}} = state) do
    case Enum.at(search.matches, search.current) do
      nil -> state
      match -> scroll_to_message(state, ChatSearch.match_message_index(match))
    end
  end

  @spec scroll_to_message(state(), non_neg_integer()) :: state()
  defp scroll_to_message(state, msg_idx) do
    messages = if state.agent.session, do: safe_messages(state.agent.session), else: []

    line_map =
      ChatRenderer.line_message_map(
        messages,
        state.viewport.cols,
        state.theme,
        state.agent.panel.display_start_index
      )

    total_lines = length(line_map)

    case Enum.find_index(line_map, fn {idx, _} -> idx == msg_idx end) do
      nil ->
        state

      line_idx ->
        scroll = max(total_lines - line_idx - 1, 0)
        update_agent(state, &AgentState.set_scroll(&1, scroll))
    end
  end

  @spec maybe_finish_review(state()) :: state()
  defp maybe_finish_review(state) do
    case Preview.diff_review(state.agentic.preview) do
      %DiffReview{} = review ->
        if DiffReview.resolved?(review), do: update_preview(state, &Preview.clear/1), else: state

      nil ->
        state
    end
  end

  @spec revert_hunk_on_disk(String.t(), map()) :: :ok
  defp revert_hunk_on_disk(path, hunk) do
    case File.read(path) do
      {:ok, content} ->
        current_lines = String.split(content, "\n")
        reverted = Diff.revert_hunk(current_lines, hunk)
        File.write(path, Enum.join(reverted, "\n"))

      {:error, _} ->
        :ok
    end
  end

  @spec revert_hunks_on_disk(String.t(), [map()]) :: :ok
  defp revert_hunks_on_disk(path, hunks) do
    case File.read(path) do
      {:ok, content} ->
        current_lines = String.split(content, "\n")

        reverted =
          Enum.reduce(hunks, current_lines, fn hunk, lines ->
            Diff.revert_hunk(lines, hunk)
          end)

        File.write(path, Enum.join(reverted, "\n"))

      {:error, _} ->
        :ok
    end
  end

  @spec should_trigger_mention?(state()) :: boolean()
  defp should_trigger_mention?(state) do
    panel = state.agent.panel
    {line, col} = panel.input_cursor
    current_line = Enum.at(panel.input_lines, line, "")
    col == 0 or String.at(current_line, col - 1) in [" ", "\t", nil]
  end

  @spec start_mention_completion(state()) :: state()
  defp start_mention_completion(state) do
    files = list_project_files()
    {line, col} = state.agent.panel.input_cursor
    completion = FileMention.new_completion(files, line, col - 1)
    update_panel(state, fn p -> %{p | mention_completion: completion} end)
  end

  @spec accept_mention_completion(state()) :: state()
  defp accept_mention_completion(state) do
    comp = state.agent.panel.mention_completion

    case FileMention.selected_path(comp) do
      nil ->
        update_panel(state, fn p -> %{p | mention_completion: nil} end)

      path ->
        panel = state.agent.panel
        {line, _col} = panel.input_cursor
        current = Enum.at(panel.input_lines, line)
        anchor_col = comp.anchor_col

        before = String.slice(current, 0, anchor_col)

        after_prefix =
          String.slice(
            current,
            anchor_col + 1 + String.length(comp.prefix),
            String.length(current)
          )

        new_line = before <> "@" <> path <> " " <> after_prefix
        new_col = anchor_col + 1 + String.length(path) + 1
        new_lines = List.replace_at(panel.input_lines, line, new_line)

        update_panel(state, fn p ->
          %{p | input_lines: new_lines, input_cursor: {line, new_col}, mention_completion: nil}
        end)
    end
  end

  @spec list_project_files() :: [String.t()]
  defp list_project_files do
    root =
      try do
        case Minga.Project.root() do
          nil -> File.cwd!()
          r -> r
        end
      catch
        :exit, _ -> File.cwd!()
      end

    case Minga.FileFind.list_files(root) do
      {:ok, paths} -> paths
      {:error, _} -> []
    end
  end
end
