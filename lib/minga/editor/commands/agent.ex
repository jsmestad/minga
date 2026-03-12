defmodule Minga.Editor.Commands.Agent do
  @moduledoc """
  Editor commands for AI agent interaction.

  Handles toggling the agent panel, submitting prompts, scrolling
  the chat, and managing agent sessions. All functions are pure
  `state → state` transformations.
  """

  alias Minga.Agent.ChatRenderer
  alias Minga.Agent.DiffReview
  alias Minga.Agent.FileMention
  alias Minga.Agent.Markdown
  alias Minga.Agent.Message
  alias Minga.Agent.PanelState
  alias Minga.Agent.Session
  alias Minga.Agent.SlashCommand
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Clipboard
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.AgentSession
  alias Minga.Editor.Commands.AgentSubStates
  alias Minga.Editor.Commands.Helpers, as: CommandHelpers
  alias Minga.Editor.Layout
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Input.Vim
  alias Minga.Surface.AgentView
  alias Minga.Surface.AgentView.State, as: AgentViewState
  alias Minga.Surface.Context

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Toggles the agent chat panel."
  @spec toggle_panel(state()) :: state()
  def toggle_panel(state) do
    panel = AgentAccess.panel(state)

    if panel.visible and not AgentAccess.input_focused?(state) do
      update_agent(state, &AgentState.focus_input(&1, true))
    else
      state = update_agent(state, &AgentState.toggle_panel/1)

      state =
        if AgentAccess.panel(state).visible and AgentAccess.session(state) == nil do
          AgentSession.start_agent_session(state)
        else
          state
        end

      state =
        if AgentAccess.panel(state).visible do
          update_agent(state, &AgentState.focus_input(&1, true))
        else
          update_agent(state, &AgentState.focus_input(&1, false))
        end

      state
      |> Layout.invalidate()
      |> EditorState.invalidate_all_windows()
    end
  end

  @doc """
  Toggles the full-screen agentic view on or off.

  On activate: switches to an agent tab (creating one if none exists),
  which snapshots the current file tab's context and restores the agent
  context. On deactivate: switches back to the most recent file tab.
  """
  @spec toggle_agentic_view(state()) :: state()
  def toggle_agentic_view(%{surface_module: Minga.Surface.AgentView} = state) do
    deactivate_agentic_view(state)
  end

  def toggle_agentic_view(state) do
    activate_agentic_view(state)
  end

  @spec deactivate_agentic_view(state()) :: state()
  defp deactivate_agentic_view(state) do
    # switch_tab handles deactivation: sync_from_editor -> deactivate_surface
    # -> snapshot. The surface's deactivate callback sets active: false.
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
  # The surface's `activate` callback sets `agentic.active = true`.
  # We also ensure `focus: :chat` for a clean return to the chat view.
  @spec switch_to_existing_agent_tab(state(), Tab.t()) :: state()
  defp switch_to_existing_agent_tab(state, agent_tab) do
    # Patch the stored surface state to set focus before switch_tab
    # calls activate. This ensures the user lands on :chat, not whatever
    # focus was saved when they left (could be :file_viewer, :dashboard).
    ctx = agent_tab.context

    ctx =
      case Map.get(ctx, :surface_state) do
        %AgentViewState{agentic: agentic} = av ->
          Map.put(ctx, :surface_state, %{av | agentic: %{agentic | focus: :chat}})

        _ ->
          ctx
      end

    tb = TabBar.update_context(state.tab_bar, agent_tab.id, ctx)

    state = %{state | tab_bar: tb}
    state = EditorState.switch_tab(state, agent_tab.id)
    maybe_start_session(state)
  end

  @spec new_agent_context(state()) :: Tab.context()
  defp new_agent_context(state) do
    agent = AgentAccess.agent(state)
    agentic = %{ViewState.new() | active: true, focus: :chat}

    av_state = %AgentViewState{
      agent: agent,
      agentic: agentic,
      context: Context.from_editor_state(state)
    }

    %{
      keymap_scope: :agent,
      surface_module: AgentView,
      surface_state: av_state
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
  # (e.g., cold boot into agent mode). The new tab starts with an empty
  # context; `EditorState.restore_tab_context` detects this and calls
  # `build_file_tab_defaults` to set up a proper window tree, editor
  # keymap scope, and buffer binding.
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
    # performs the full snapshot/restore cycle. The tab has empty
    # context, which triggers build_file_tab_defaults during restore.
    {tb, file_tab} = TabBar.insert(tb, :file, label)
    state = %{state | tab_bar: tb}
    EditorState.switch_tab(state, file_tab.id)
  end

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
      PanelState.input_empty?(panel) ->
        state

      AgentAccess.session(state) == nil ->
        %{state | status_msg: "No agent session, try closing and reopening the panel"}

      true ->
        text = PanelState.prompt_text(panel)

        if SlashCommand.slash_command?(text) do
          state = update_agent(state, &AgentState.clear_input_and_scroll/1)
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
      {:error, msg} -> %{state | status_msg: msg}
    end
  end

  @spec send_prompt_to_llm(state(), String.t()) :: state()
  defp send_prompt_to_llm(state, text) do
    # Resolve @file mentions before sending to the LLM
    with {:ok, resolved_text} <- resolve_mentions(text),
         :ok <- Session.send_prompt(AgentAccess.session(state), resolved_text) do
      state = update_agent(state, &AgentState.clear_input_and_scroll/1)

      AgentAccess.update_agentic(state, fn _ ->
        ViewState.clear_baselines(AgentAccess.agentic(state))
      end)
    else
      {:error, :provider_not_ready} ->
        %{state | status_msg: "Agent provider still starting, try again in a moment"}

      {:error, msg} when is_binary(msg) ->
        %{state | status_msg: msg}

      {:error, reason} ->
        %{state | status_msg: "Agent error: #{inspect(reason)}"}
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
      if AgentAccess.session(state) do
        try do
          length(Session.messages(AgentAccess.session(state)))
        catch
          :exit, _ -> 0
        end
      else
        0
      end

    state = update_agent(state, &AgentState.clear_display(&1, msg_count))

    if AgentAccess.session(state) do
      Session.add_system_message(AgentAccess.session(state), "Display cleared")
    end

    state
  end

  @doc "Aborts the current agent operation."
  @spec abort_agent(state()) :: state()
  def abort_agent(state) do
    if AgentAccess.session(state) == nil do
      state
    else
      Session.abort(AgentAccess.session(state))
      state
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
  def new_agent_session(%{tab_bar: %TabBar{}} = state) do
    # Snapshot current tab before leaving it.
    current_id = state.tab_bar.active_id
    current_ctx = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(state.tab_bar, current_id, current_ctx)

    # Add new agent tab (becomes active).
    {tb, agent_tab} = TabBar.add(tb, :agent, "New Agent")

    # Fresh agent state for the new tab.
    agent_context = new_agent_context(state)

    tb = TabBar.update_context(tb, agent_tab.id, agent_context)
    state = %{state | tab_bar: tb}
    state = EditorState.restore_tab_context(state, agent_context)
    AgentSession.start_agent_session(state)
  end

  # Fallback for bare maps or states without a tab bar (tests, slash commands).
  def new_agent_session(state) do
    AgentSession.start_agent_session(state)
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
          %{tab_bar: %TabBar{active_id: id}} ->
            EditorState.set_tab_session(state, id, pid)

          _ ->
            state
        end

      # Reset panel scroll and auto-scroll to reflect new session's content
      update_agent(state, fn agent ->
        panel = %{agent.panel | scroll: Minga.Scroll.new()}
        %{agent | panel: panel}
      end)
    end
  end

  @doc "Scrolls the chat panel up by half the panel height."
  @spec scroll_chat_up(state()) :: state()
  def scroll_chat_up(state) do
    if no_agent_ui?(state), do: state, else: do_scroll_chat_up(state)
  end

  defp do_scroll_chat_up(state) do
    amount = div(panel_height(state), 2)
    update_agent(state, &AgentState.scroll_up(&1, amount))
  end

  @doc "Scrolls the chat panel down by half the panel height."
  @spec scroll_chat_down(state()) :: state()
  def scroll_chat_down(state) do
    if no_agent_ui?(state), do: state, else: do_scroll_chat_down(state)
  end

  defp do_scroll_chat_down(state) do
    amount = div(panel_height(state), 2)
    update_agent(state, &AgentState.scroll_down(&1, amount))
  end

  @doc "Handles a character input in the agent prompt."
  @spec input_char(state(), String.t()) :: state()
  def input_char(state, char) do
    if no_agent_ui?(state),
      do: state,
      else: update_agent(state, &AgentState.insert_char(&1, char))
  end

  @doc "Inserts pasted text into the agent prompt. Collapses multi-line pastes into a compact indicator."
  @spec input_paste(state(), String.t()) :: state()
  def input_paste(state, text) do
    if no_agent_ui?(state),
      do: state,
      else: update_agent(state, &AgentState.insert_paste(&1, text))
  end

  @doc "Toggles expand/collapse on the paste block at the cursor."
  @spec toggle_paste_expand(state()) :: state()
  def toggle_paste_expand(state) do
    update_agent(state, &AgentState.toggle_paste_expand/1)
  end

  @doc "Deletes the last character from the agent prompt."
  @spec input_backspace(state()) :: state()
  def input_backspace(state) do
    if no_agent_ui?(state), do: state, else: update_agent(state, &AgentState.delete_char/1)
  end

  @doc "Cycles the thinking level (off → low → medium → high)."
  @spec cycle_thinking_level(state()) :: state()
  def cycle_thinking_level(state) do
    if AgentAccess.session(state) == nil do
      %{state | status_msg: "No agent session"}
    else
      case Session.cycle_thinking_level(AgentAccess.session(state)) do
        {:ok, %{"level" => level}} when is_binary(level) ->
          state = update_agent(state, &AgentState.set_thinking_level(&1, level))
          Session.add_system_message(AgentAccess.session(state), "Thinking: #{level}")
          %{state | status_msg: "Thinking: #{level}"}

        {:ok, nil} ->
          %{state | status_msg: "Model does not support thinking levels"}

        {:error, reason} ->
          %{state | status_msg: "Error: #{inspect(reason)}"}
      end
    end
  end

  @doc "Sets the agent provider and restarts the session."
  @spec set_provider(state(), String.t()) :: state()
  def set_provider(state, provider) do
    state = update_agent(state, &AgentState.set_provider_name(&1, provider))
    AgentSession.restart_session(state, "Provider: #{provider}")
  end

  @doc "Sets the agent model and restarts the session."
  @spec set_model(state(), String.t()) :: state()
  def set_model(state, model) do
    state = update_agent(state, &AgentState.set_model_name(&1, model))
    AgentSession.restart_session(state, "Model: #{model}")
  end

  # ── Scope commands (keymap scope dispatch) ──────────────────────────────────
  #
  # These commands are bound in Keymap.Scope.Agent and dispatched through the
  # scope resolution system. Focus-aware commands check state.agentic.focus to
  # route to the correct panel (chat vs file viewer).

  # ── Navigation ─────────────────────────────────────────────────────────────

  @doc "Scrolls down 1 line in the focused panel."
  @spec scope_scroll_down(state()) :: state()
  def scope_scroll_down(state) do
    if AgentAccess.agentic(state).focus == :file_viewer do
      update_agentic(state, &ViewState.scroll_viewer_down(&1, 1))
    else
      update_agent(state, &AgentState.scroll_down(&1, 1))
    end
  end

  @doc "Scrolls up 1 line in the focused panel."
  @spec scope_scroll_up(state()) :: state()
  def scope_scroll_up(state) do
    if AgentAccess.agentic(state).focus == :file_viewer do
      update_agentic(state, &ViewState.scroll_viewer_up(&1, 1))
    else
      update_agent(state, &AgentState.scroll_up(&1, 1))
    end
  end

  @doc "Scrolls down half a page in the focused panel."
  @spec scope_scroll_half_down(state()) :: state()
  def scope_scroll_half_down(state) do
    amount = half_page(state)

    if AgentAccess.agentic(state).focus == :file_viewer do
      update_agentic(state, &ViewState.scroll_viewer_down(&1, amount))
    else
      update_agent(state, &AgentState.scroll_down(&1, amount))
    end
  end

  @doc "Scrolls up half a page in the focused panel."
  @spec scope_scroll_half_up(state()) :: state()
  def scope_scroll_half_up(state) do
    amount = half_page(state)

    if AgentAccess.agentic(state).focus == :file_viewer do
      update_agentic(state, &ViewState.scroll_viewer_up(&1, amount))
    else
      update_agent(state, &AgentState.scroll_up(&1, amount))
    end
  end

  @doc "Scrolls to the bottom of the focused panel."
  @spec scope_scroll_bottom(state()) :: state()
  def scope_scroll_bottom(state) do
    if AgentAccess.agentic(state).focus == :file_viewer do
      update_agentic(state, &ViewState.scroll_viewer_to_bottom/1)
    else
      update_agent(state, &AgentState.scroll_to_bottom/1)
    end
  end

  @doc "Scrolls to the top of the focused panel."
  @spec scope_scroll_top(state()) :: state()
  def scope_scroll_top(state) do
    if AgentAccess.agentic(state).focus == :file_viewer do
      update_agentic(state, &ViewState.scroll_viewer_to_top/1)
    else
      update_agent(state, &AgentState.scroll_to_top/1)
    end
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
  def scope_next_code_block(state) do
    case AgentAccess.agentic(state).preview do
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
    case AgentAccess.agentic(state).preview do
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

  # ── Input vim mode commands ──────────────────────────────────────────────
  #
  # Vim editing (motions, operators, visual mode, counts, text objects) is
  # handled entirely by Minga.Input.Vim.handle_key/4 in the dispatch layer.
  # Only mode transitions that originate from scope trie bindings live here.

  @doc "Switches the input from insert to normal mode (called on Escape in insert)."
  @spec input_to_normal(state()) :: state()
  def input_to_normal(state) do
    update_agent(state, fn agent ->
      {new_vim, new_tf} = Vim.enter_normal(agent.panel.vim, agent.panel.input)
      %{agent | panel: %{agent.panel | vim: new_vim, input: new_tf}}
    end)
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
  def scope_switch_focus(state) do
    if AgentAccess.agentic(state).focus == :chat do
      update_agentic(state, &ViewState.set_focus(&1, :file_viewer))
    else
      update_agentic(state, &ViewState.set_focus(&1, :chat))
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
  def scope_dismiss_or_noop(state) do
    if AgentAccess.agentic(state).help_visible do
      update_agentic(state, &ViewState.dismiss_help/1)
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

  @doc "Inserts a newline in the input field."
  @spec scope_insert_newline(state()) :: state()
  def scope_insert_newline(state) do
    update_agent(state, &AgentState.insert_newline/1)
  end

  @doc "Submits if input has text, aborts if agent is active."
  @spec scope_submit_or_abort(state()) :: state()
  def scope_submit_or_abort(state) do
    if PanelState.prompt_text(AgentAccess.panel(state)) != "" do
      submit_prompt(state)
    else
      abort_if_active(state)
    end
  end

  @doc "Moves cursor up in input or recalls history."
  @spec scope_input_up(state()) :: state()
  def scope_input_up(state) do
    panel = AgentAccess.panel(state)
    {line, _col} = PanelState.input_cursor(panel)

    if line == 0 do
      update_agent(state, &AgentState.history_prev/1)
    else
      update_agent(state, &AgentState.move_cursor_up/1)
    end
  end

  @doc "Moves cursor down in input or advances history."
  @spec scope_input_down(state()) :: state()
  def scope_input_down(state) do
    panel = AgentAccess.panel(state)
    {line, _col} = PanelState.input_cursor(panel)
    max_line = PanelState.input_line_count(panel) - 1

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

  # ── Delegated to AgentSession ──────────────────────────────────────────────

  defdelegate open_code_block(state, language, content), to: AgentSession

  # ── Private helpers ─────────────────────────────────────────────────────────

  # Returns true when neither the full-screen agent view nor the side panel
  # is visible, meaning agent input/scroll commands should be no-ops.
  @spec no_agent_ui?(state()) :: boolean()
  defp no_agent_ui?(%{surface_module: AgentView}), do: false

  defp no_agent_ui?(state) do
    not AgentAccess.panel(state).visible
  end

  @spec update_agent(state(), (AgentState.t() -> AgentState.t())) :: state()
  defp update_agent(state, fun), do: AgentAccess.update_agent(state, fun)

  @spec update_agentic(state(), (ViewState.t() -> ViewState.t())) :: state()
  defp update_agentic(state, fun), do: AgentAccess.update_agentic(state, fun)

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    AgentAccess.update_agentic(state, &ViewState.update_preview(&1, fun))
  end

  @spec panel_height(state()) :: non_neg_integer()
  defp panel_height(state) do
    div(state.viewport.rows * 35, 100)
  end

  @spec half_page(state()) :: pos_integer()
  defp half_page(state), do: max(div(state.viewport.rows, 2), 1)

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
          {non_neg_integer(), Message.t(), ChatRenderer.line_type()} | nil
  defp scroll_context(state) do
    session = AgentAccess.session(state)
    panel = AgentAccess.panel(state)

    if session do
      messages = safe_messages(session)
      theme = state.theme
      width = state.viewport.cols

      line_map =
        ChatRenderer.line_message_map(messages, width, theme, panel.display_start_index)

      # Use Scroll.resolve to get the effective scroll position, treating
      # the line_map length as content and 1 as "visible" to get the
      # line index at the current scroll position.
      total = length(line_map)
      target = Minga.Scroll.resolve(panel.scroll, total, 1)

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

        update_agentic(state, &ViewState.push_toast(&1, "Copied #{label}", :info))

      _error ->
        if AgentAccess.session(state) do
          Session.add_system_message(AgentAccess.session(state), "Clipboard write failed", :error)
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
    session = AgentAccess.session(state)
    panel = AgentAccess.panel(state)
    messages = safe_messages(session)

    line_map =
      ChatRenderer.line_message_map(
        messages,
        state.viewport.cols,
        state.theme,
        panel.display_start_index
      )

    total = length(line_map)
    target = Minga.Scroll.resolve(panel.scroll, total, 1)

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
end
