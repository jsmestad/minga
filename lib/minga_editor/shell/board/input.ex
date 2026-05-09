defmodule MingaEditor.Shell.Board.Input do
  @moduledoc """
  Input handler for The Board grid view.

  Active only when Shell.Board is the active shell and the grid is
  showing (not zoomed into a card). Handles:

  - Arrow keys / h,j,k,l: navigate between cards
  - Enter: zoom into the focused card
  - Escape / q: switch back to Shell.Traditional
  - n: create a new agent card and zoom into it

  All other keys pass through to global bindings (Ctrl+Q, Ctrl+S, etc.).
  When zoomed into a card, this handler is not in the stack; the
  Traditional handler stack takes over.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.SessionManager
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Workspace.State, as: WorkspaceState
  alias MingaEditor.Shell.Board
  alias MingaEditor.Shell.Board.Card
  alias MingaEditor.Shell.Board.State, as: BoardState

  # ── Key constants ──────────────────────────────────────────────────────

  # Vim navigation
  @key_h ?h
  @key_j ?j
  @key_k ?k
  @key_l ?l

  # Actions
  @key_enter 13
  @key_escape 27
  @key_q ?q
  @key_n ?n
  @key_d ?d
  @key_x ?x

  # Kitty keyboard protocol arrow keys
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  # macOS NSEvent arrow keys (GUI frontend)
  @ns_up 0xF700
  @ns_down 0xF701
  @ns_left 0xF702
  @ns_right 0xF703

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # Filter mode: route keys to filter input
  def handle_key(
        %{shell: Board, shell_state: %BoardState{zoomed_into: nil, filter_mode: true}} = state,
        cp,
        mods
      ) do
    dispatch_filter_key(state, cp, mods)
  end

  # Only active when Board shell is showing the grid
  def handle_key(%{shell: Board, shell_state: %BoardState{zoomed_into: nil}} = state, cp, mods) do
    dispatch_grid_key(state, cp, mods)
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  # ── Grid key dispatch ──────────────────────────────────────────────────

  @spec dispatch_grid_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # Navigation: move focus between cards
  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_j, @arrow_down, @ns_down] do
    {:handled, move_focus(state, :down)}
  end

  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_k, @arrow_up, @ns_up] do
    {:handled, move_focus(state, :up)}
  end

  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_l, @arrow_right, @ns_right] do
    {:handled, move_focus(state, :right)}
  end

  defp dispatch_grid_key(state, cp, _mods) when cp in [@key_h, @arrow_left, @ns_left] do
    {:handled, move_focus(state, :left)}
  end

  # Enter: zoom into the focused card
  defp dispatch_grid_key(state, @key_enter, _mods) do
    board = state.shell_state

    case BoardState.focused(board) do
      nil ->
        {:handled, state}

      _card ->
        {:handled, zoom_into_focused(state)}
    end
  end

  # n: dispatch a new agent
  defp dispatch_grid_key(state, @key_n, _mods) do
    state = create_new_card(state)
    persist_board(state)
    {:handled, state}
  end

  # 1-9: jump to card by position
  defp dispatch_grid_key(state, cp, 0) when cp >= ?1 and cp <= ?9 do
    board = state.shell_state
    index = cp - ?1
    cards = BoardState.sorted_cards(board)

    case Enum.at(cards, index) do
      nil ->
        {:handled, state}

      card ->
        {:handled, EditorState.update_shell_state(state, &BoardState.focus_card(&1, card.id))}
    end
  end

  # /: open search filter
  defp dispatch_grid_key(state, ?/, 0) do
    {:handled, EditorState.update_shell_state(state, &BoardState.enter_filter/1)}
  end

  # d / x: delete the focused card (can't delete "You" card)
  defp dispatch_grid_key(state, cp, 0) when cp in [@key_d, @key_x] do
    board = state.shell_state
    card = BoardState.focused(board)

    if card && !Card.you_card?(card) do
      # Stop the agent session if running. SessionManager owns lifecycle events.
      if card.session, do: stop_session(card.session)

      new_board = BoardState.remove_card(board, card.id)
      state = EditorState.update_shell_state(state, fn _ -> new_board end)
      persist_board(state)
      {:handled, state}
    else
      {:handled, state}
    end
  end

  # Escape / q (unmodified): toggle back to Shell.Traditional, stash Board state
  defp dispatch_grid_key(state, cp, 0) when cp in [@key_escape, @key_q] do
    board_state = state.shell_state

    new_state =
      EditorState.switch_from_board_to_traditional(
        state,
        board_state,
        board_state.suppress_tool_prompts
      )

    {:handled, new_state}
  end

  # Ctrl/Cmd-modified keys pass through to GlobalBindings (Ctrl+Q quit,
  # Ctrl+S save, etc.). All other unbound keys are consumed: in grid mode
  # there's no buffer to type into, and letting keys reach the vim Mode FSM
  # would crash on Board.State (no :whichkey field).
  defp dispatch_grid_key(state, _cp, mods) when mods != 0 do
    {:passthrough, state}
  end

  defp dispatch_grid_key(state, _cp, _mods) do
    {:handled, state}
  end

  # ── Filter input ────────────────────────────────────────────────────────

  @backspace 127

  @spec dispatch_filter_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # Escape: cancel filter
  defp dispatch_filter_key(state, @key_escape, 0) do
    {:handled, EditorState.update_shell_state(state, &BoardState.exit_filter/1)}
  end

  # Enter: select the first matching card and exit filter
  defp dispatch_filter_key(state, @key_enter, _mods) do
    board = state.shell_state
    matches = BoardState.filtered_cards(board)

    new_board =
      case matches do
        [first | _] ->
          board
          |> BoardState.exit_filter()
          |> BoardState.focus_card(first.id)

        [] ->
          BoardState.exit_filter(board)
      end

    {:handled, EditorState.update_shell_state(state, fn _ -> new_board end)}
  end

  # Backspace: delete last character
  defp dispatch_filter_key(state, @backspace, _mods) do
    {:handled, EditorState.update_shell_state(state, &BoardState.delete_filter_char/1)}
  end

  defp dispatch_filter_key(state, cp, _mods)
       when cp in [
              @arrow_up,
              @arrow_down,
              @arrow_left,
              @arrow_right,
              @ns_up,
              @ns_down,
              @ns_left,
              @ns_right
            ] do
    {:handled, state}
  end

  # Printable characters: append to filter
  defp dispatch_filter_key(state, cp, _mods) when cp >= 32 and cp <= 0x10FFFF do
    {:handled, EditorState.update_shell_state(state, &BoardState.append_filter_char(&1, cp))}
  end

  # Everything else: passthrough for Ctrl combos
  defp dispatch_filter_key(state, _cp, _mods), do: {:passthrough, state}

  # ── Actions ────────────────────────────────────────────────────────────

  @spec move_focus(EditorState.t(), :up | :down | :left | :right) :: EditorState.t()
  defp move_focus(state, direction) do
    board = state.shell_state
    # Use the grid columns from the last computed layout, default to 3
    cols = grid_cols(state)
    new_board = BoardState.move_focus(board, direction, cols)
    EditorState.update_shell_state(state, fn _ -> new_board end)
  end

  @spec zoom_into_focused(EditorState.t()) :: EditorState.t()
  defp zoom_into_focused(state) do
    board = state.shell_state
    card = BoardState.focused(board)

    if card do
      # Store the current workspace as the "board grid" snapshot on
      # the zoomed card. This gets restored when zooming back out.
      current_workspace = WorkspaceState.to_tab_context(state.workspace)
      new_board = BoardState.zoom_into(board, card.id, current_workspace)
      state = EditorState.update_shell_state(state, fn _ -> new_board end)

      # Restore the card's workspace if it has one from a previous zoom.
      # First zoom: build a fresh agent-shaped workspace (own window with
      # agent_chat content, agent scope, default agent_ui) so activate_for_card
      # operates on a card-shaped window, not the grid's buffer window.
      state =
        case card.workspace do
          ws when is_map(ws) and map_size(ws) > 0 ->
            EditorState.restore_tab_context(state, ws)

          _ ->
            agent_buf = AgentAccess.agent(state).buffer
            fresh_context = EditorState.build_agent_card_workspace(state, agent_buf)
            EditorState.restore_tab_context(state, fresh_context)
        end

      # For agent cards, activate the agentic view so the user sees
      # the agent chat, not a plain buffer
      MingaEditor.AgentActivation.activate_for_card(state, card)
    else
      state
    end
  end

  @spec create_new_card(EditorState.t()) :: EditorState.t()
  defp create_new_card(state) do
    board = state.shell_state
    count = BoardState.card_count(board)
    model = resolve_model()

    {board, card} =
      BoardState.create_card(board, task: "Agent #{count}", model: model, status: :working)

    board = BoardState.focus_card(board, card.id)

    # Start an agent session and attach it to the card
    {board, state} = start_and_attach_session(board, card.id, model, state)

    # Snapshot current workspace and zoom into the card
    workspace_snapshot = WorkspaceState.to_tab_context(state.workspace)
    board = BoardState.zoom_into(board, card.id, workspace_snapshot)
    state = EditorState.update_shell_state(state, fn _ -> board end)

    # Activate the agentic view for the new card
    card = board.cards[card.id]
    MingaEditor.AgentActivation.activate_for_card(state, card)
  end

  @spec start_and_attach_session(BoardState.t(), pos_integer(), String.t(), EditorState.t()) ::
          {BoardState.t(), EditorState.t()}
  defp start_and_attach_session(board, card_id, model, state) do
    opts = [
      provider_opts: [
        provider: resolve_provider(),
        model: model
      ]
    ]

    case start_session(opts) do
      {:ok, pid} ->
        board = BoardState.update_card(board, card_id, &Card.attach_session(&1, pid))

        # The session pid lives on the card (set above via Card.attach_session).
        # The rendering cache on state.shell_state.agent is repopulated when
        # the user zooms into this card via AgentActivation.activate_for_card/2.

        Minga.Log.info(:agent, "Board: started agent session for card #{card_id} (#{model})")
        {board, state}

      {:error, reason} ->
        Minga.Log.error(:agent, "Board: failed to start agent: #{inspect(reason)}")
        board = BoardState.update_card(board, card_id, &Card.set_status(&1, :errored))
        {board, state}
    end
  end

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_session(opts) do
    case SessionManager.start_session(opts) do
      {:ok, _session_id, pid} ->
        subscribe_session(pid)

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec subscribe_session(pid()) :: {:ok, pid()} | {:error, term()}
  defp subscribe_session(pid) do
    AgentSession.subscribe(pid)
    {:ok, pid}
  catch
    :exit, reason ->
      stop_session(pid)
      {:error, reason}
  end

  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  defp stop_session(pid) do
    SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  defp resolve_model, do: AgentConfig.resolve_model()
  defp resolve_provider, do: AgentConfig.resolve_provider()

  # ── Helpers ────────────────────────────────────────────────────────────

  @spec grid_cols(EditorState.t()) :: pos_integer()
  defp grid_cols(%{layout: %{grid_cols: cols}}) when is_integer(cols) and cols > 0, do: cols

  defp grid_cols(%{workspace: %{viewport: %{cols: vp_cols}}}) do
    # Estimate columns from viewport width (matching Layout computation)
    max(div(vp_cols, 26), 1)
  end

  defp grid_cols(_state), do: 3

  @spec persist_board(EditorState.t()) :: :ok
  defp persist_board(%{shell_state: %BoardState{} = board}) do
    # Fire and forget: persistence errors are logged but don't affect UX
    Task.start(fn -> MingaEditor.Shell.Board.Persistence.save(board) end)
    :ok
  end

  defp persist_board(_state), do: :ok
end
