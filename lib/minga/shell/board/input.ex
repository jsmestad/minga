defmodule Minga.Shell.Board.Input do
  @moduledoc """
  Input handler for The Board grid view.

  Active only when Shell.Board is the active shell and the grid is
  showing (not zoomed into a card). Handles:

  - Arrow keys / h,j,k,l: navigate between cards
  - Enter: zoom into the focused card
  - Escape / q: switch back to Shell.Traditional
  - n: dispatch a new agent (opens the dispatch prompt)

  All other keys pass through to global bindings (Ctrl+Q, Ctrl+S, etc.).
  When zoomed into a card, this handler is not in the stack; the
  Traditional handler stack takes over.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.State, as: EditorState
  alias Minga.Shell.Board
  alias Minga.Shell.Board.Card
  alias Minga.Shell.Board.State, as: BoardState

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
          Minga.Input.Handler.result()

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
          Minga.Input.Handler.result()

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
      nil -> {:handled, state}
      card -> {:handled, %{state | shell_state: BoardState.focus_card(board, card.id)}}
    end
  end

  # /: open search filter
  defp dispatch_grid_key(state, ?/, 0) do
    board = state.shell_state
    {:handled, %{state | shell_state: %{board | filter_mode: true, filter_text: ""}}}
  end

  # d / x: delete the focused card (can't delete "You" card)
  defp dispatch_grid_key(state, cp, 0) when cp in [@key_d, @key_x] do
    board = state.shell_state
    card = BoardState.focused(board)

    if card && !Card.you_card?(card) do
      # Kill the agent session if running
      if card.session do
        try do
          Minga.Agent.Session.abort(card.session)
        catch
          :exit, _ -> :ok
        end
      end

      new_board = BoardState.remove_card(board, card.id)
      state = %{state | shell_state: new_board}
      persist_board(state)
      {:handled, state}
    else
      {:handled, state}
    end
  end

  # Escape / q (unmodified): toggle back to Shell.Traditional, stash Board state
  defp dispatch_grid_key(state, cp, 0) when cp in [@key_escape, @key_q] do
    board_state = state.shell_state

    traditional_state = %Minga.Shell.Traditional.State{
      suppress_tool_prompts: board_state.suppress_tool_prompts
    }

    new_state = %{
      state
      | shell: Minga.Shell.Traditional,
        shell_state: traditional_state,
        layout: nil,
        stashed_board_state: board_state
    }

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
          Minga.Input.Handler.result()

  # Escape: cancel filter
  defp dispatch_filter_key(state, @key_escape, 0) do
    board = %{state.shell_state | filter_mode: false, filter_text: ""}
    {:handled, %{state | shell_state: board}}
  end

  # Enter: select the first matching card and exit filter
  defp dispatch_filter_key(state, @key_enter, _mods) do
    board = state.shell_state
    matches = BoardState.filtered_cards(board)

    board =
      case matches do
        [first | _] ->
          BoardState.focus_card(%{board | filter_mode: false, filter_text: ""}, first.id)

        [] ->
          %{board | filter_mode: false, filter_text: ""}
      end

    {:handled, %{state | shell_state: board}}
  end

  # Backspace: delete last character
  defp dispatch_filter_key(state, @backspace, _mods) do
    board = state.shell_state
    new_text = String.slice(board.filter_text, 0..-2//1)
    {:handled, %{state | shell_state: %{board | filter_text: new_text}}}
  end

  # Printable characters: append to filter
  defp dispatch_filter_key(state, cp, _mods) when cp >= 32 do
    board = state.shell_state
    new_text = board.filter_text <> <<cp::utf8>>
    {:handled, %{state | shell_state: %{board | filter_text: new_text}}}
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
    %{state | shell_state: new_board}
  end

  @spec zoom_into_focused(EditorState.t()) :: EditorState.t()
  defp zoom_into_focused(state) do
    board = state.shell_state
    card = BoardState.focused(board)

    if card do
      # Store the current workspace as the "board grid" snapshot on
      # the zoomed card. This gets restored when zooming back out.
      current_workspace = Map.from_struct(state.workspace)
      new_board = BoardState.zoom_into(board, card.id, current_workspace)
      state = %{state | shell_state: new_board}

      # Restore the card's workspace if it has one from a previous zoom
      state =
        case card.workspace do
          ws when is_map(ws) and map_size(ws) > 0 ->
            EditorState.restore_tab_context(state, ws)

          _ ->
            state
        end

      # For agent cards, activate the agentic view so the user sees
      # the agent chat, not a plain buffer
      if Card.you_card?(card) do
        state
      else
        activate_agent_view(state, card)
      end
    else
      state
    end
  end

  @spec activate_agent_view(EditorState.t(), Card.t()) :: EditorState.t()
  defp activate_agent_view(state, card) do
    # Attach the session so agent events route correctly
    state =
      if card.session do
        Minga.Editor.State.AgentAccess.update_agent(state, fn a ->
          Minga.Editor.State.Agent.set_session(a, card.session)
        end)
      else
        state
      end

    # Switch to agent scope so the agent chat/panel renders.
    # This is a lighter approach than toggle_agentic_view which
    # depends on the Traditional tab system.
    ws = %{state.workspace | keymap_scope: :agent}

    # Make the agent panel visible
    state =
      Minga.Editor.State.AgentAccess.update_agent_ui(state, fn ui ->
        Minga.Agent.UIState.set_input_focused(ui, true)
      end)

    %{state | workspace: ws}
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
    workspace_snapshot = Map.from_struct(state.workspace)
    board = BoardState.zoom_into(board, card.id, workspace_snapshot)
    state = %{state | shell_state: board}

    # Activate the agentic view for the new card
    card = board.cards[card.id]
    activate_agent_view(state, card)
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

    case DynamicSupervisor.start_child(Minga.Agent.Supervisor, {Minga.Agent.Session, opts}) do
      {:ok, pid} ->
        board = BoardState.update_card(board, card_id, &Card.attach_session(&1, pid))

        # Monitor session for :DOWN
        ref = Process.monitor(pid)
        monitors = Map.put(state.buffer_monitors, pid, ref)
        state = %{state | buffer_monitors: monitors}

        # Subscribe editor to agent events
        Minga.Agent.Session.subscribe(pid)

        # Store session on agent state so events route correctly
        state =
          Minga.Editor.State.AgentAccess.update_agent(state, fn a ->
            Minga.Editor.State.Agent.set_session(a, pid)
          end)

        Minga.Log.info(:agent, "Board: started agent session for card #{card_id} (#{model})")
        {board, state}

      {:error, reason} ->
        Minga.Log.error(:agent, "Board: failed to start agent: #{inspect(reason)}")
        board = BoardState.update_card(board, card_id, &Card.set_status(&1, :errored))
        {board, state}
    end
  catch
    :exit, reason ->
      Minga.Log.error(:agent, "Board: agent supervisor not available: #{inspect(reason)}")
      board = BoardState.update_card(board, card_id, &Card.set_status(&1, :errored))
      {board, state}
  end

  @spec resolve_model() :: String.t()
  defp resolve_model do
    case Minga.Config.get(:agent_model) do
      nil -> "claude-sonnet-4-20250514"
      model -> to_string(model)
    end
  catch
    :exit, _ -> "claude-sonnet-4-20250514"
  end

  @spec resolve_provider() :: atom()
  defp resolve_provider do
    Minga.Config.get(:agent_provider) || :auto
  catch
    :exit, _ -> :auto
  end

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
    Task.start(fn -> Minga.Shell.Board.Persistence.save(board) end)
    :ok
  end

  defp persist_board(_state), do: :ok
end
