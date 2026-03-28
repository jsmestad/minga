defmodule Minga.Shell.Board do
  @moduledoc """
  The Board shell: agent supervisor card view.

  Displays agent sessions as cards on a spatial grid. Each card shows
  task description, status, model, and elapsed time. Clicking a card
  (or pressing Enter) zooms into its workspace for full editing.

  The Board stays the active shell even when zoomed into a card. In
  grid mode, it renders the card grid and handles navigation input.
  In zoomed mode, it delegates rendering and input to the traditional
  editor pipeline for the active card's workspace.

  ## Two rendering modes

  - **Grid view** (`zoomed_into: nil`): card rectangles with status
    badges, task text, and model labels. Board-specific input handlers.
  - **Zoomed view** (`zoomed_into: card_id`): full editor rendering
    using the card's restored workspace. Traditional input handlers
    plus an Escape binding to zoom back out.
  """

  @behaviour Minga.Shell

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame}
  alias Minga.Frontend.Emit.Context, as: EmitContext
  alias Minga.Shell.Board.Card
  alias Minga.Shell.Board.State, as: BoardState

  @impl true
  @spec init(keyword()) :: Minga.Shell.shell_state()
  def init(opts \\ []) do
    # Try to restore persisted board state from disk (skip in test env)
    skip_persistence = Keyword.get(opts, :skip_persistence, false)

    case if(skip_persistence, do: nil, else: Minga.Shell.Board.Persistence.load()) do
      %BoardState{} = restored ->
        ensure_you_card(restored)

      nil ->
        state = BoardState.new()
        {state, _you_card} = BoardState.create_card(state, task: "You", status: :idle, kind: :you)

        # If initial cards were passed (e.g., tests), add them
        Enum.reduce(Keyword.get(opts, :cards, []), state, fn card_attrs, acc ->
          {acc, _card} = BoardState.create_card(acc, card_attrs)
          acc
        end)
    end
  end

  @impl true
  @spec handle_event(BoardState.t(), Minga.Workspace.State.t(), term()) ::
          {BoardState.t(), Minga.Workspace.State.t()}
  def handle_event(shell_state, workspace, _event) do
    # TODO: handle agent status updates, card lifecycle events
    {shell_state, workspace}
  end

  @impl true
  @spec handle_gui_action(BoardState.t(), Minga.Workspace.State.t(), term()) ::
          {BoardState.t(), Minga.Workspace.State.t()}
  def handle_gui_action(shell_state, workspace, {:board_select_card, card_id}) do
    # GUI card click: focus, zoom in, activate agent view.
    # Same logic as Board.Input's Enter key handler.
    shell_state = BoardState.focus_card(shell_state, card_id)
    workspace_snapshot = Map.from_struct(workspace)
    shell_state = BoardState.zoom_into(shell_state, card_id, workspace_snapshot)

    # Restore the card's workspace if it has one
    card = BoardState.zoomed(shell_state)

    workspace =
      case card && card.workspace do
        ws when is_map(ws) and map_size(ws) > 0 ->
          struct!(Minga.Workspace.State, ws)

        _ ->
          workspace
      end

    # Agent activation (session, scope, window content, prompt focus) is
    # handled by Editor.AgentActivation.activate_for_card/2 after this
    # function returns. The Shell behaviour only has (shell_state, workspace)
    # access; full EditorState is needed for session attachment.

    {shell_state, workspace}
  end

  def handle_gui_action(shell_state, workspace, {:board_close_card, card_id}) do
    shell_state = BoardState.remove_card(shell_state, card_id)
    Minga.Shell.Board.Persistence.save(shell_state)
    {shell_state, workspace}
  end

  def handle_gui_action(shell_state, workspace, {:board_reorder, card_id, new_index}) do
    shell_state = BoardState.reorder_card(shell_state, card_id, new_index)
    Minga.Shell.Board.Persistence.save(shell_state)
    {shell_state, workspace}
  end

  def handle_gui_action(shell_state, workspace, {:board_dispatch_agent, task, model}) do
    {shell_state, card} =
      BoardState.create_card(shell_state,
        task: task,
        model: model,
        status: :working,
        kind: :agent
      )

    Minga.Log.info(:agent, "Board: dispatched agent card ##{card.id} (#{model}): #{task}")

    # Start an agent session for this card
    case Minga.Agent.Supervisor.start_session(
           provider_opts: [model: model],
           thinking_level: :normal
         ) do
      {:ok, pid} ->
        shell_state =
          BoardState.update_card(shell_state, card.id, fn c ->
            %{c | session: pid}
          end)

        # Send the task as the initial prompt
        Minga.Agent.Session.send_prompt(pid, task)

        Minga.Shell.Board.Persistence.save(shell_state)
        {shell_state, workspace}

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Board: failed to start session for card ##{card.id}: #{inspect(reason)}"
        )

        shell_state =
          BoardState.update_card(shell_state, card.id, fn c ->
            %{c | status: :errored}
          end)

        Minga.Shell.Board.Persistence.save(shell_state)
        {shell_state, workspace}
    end
  end

  def handle_gui_action(shell_state, workspace, :agent_approve) do
    # Approve the agent's work: transition card to :done status
    case shell_state.zoomed_into do
      nil ->
        {shell_state, workspace}

      card_id ->
        card = Map.get(shell_state.cards, card_id)

        if card && !Card.you_card?(card) do
          updated_card = Card.set_status(card, :done)
          shell_state = %{shell_state | cards: Map.put(shell_state.cards, card_id, updated_card)}
          Minga.Shell.Board.Persistence.save(shell_state)
          {shell_state, workspace}
        else
          {shell_state, workspace}
        end
    end
  end

  def handle_gui_action(shell_state, workspace, :agent_request_changes) do
    # Request changes from the agent: transition card to :needs_you status
    case shell_state.zoomed_into do
      nil ->
        {shell_state, workspace}

      card_id ->
        card = Map.get(shell_state.cards, card_id)

        if card && !Card.you_card?(card) do
          updated_card = Card.set_status(card, :needs_you)
          shell_state = %{shell_state | cards: Map.put(shell_state.cards, card_id, updated_card)}
          Minga.Shell.Board.Persistence.save(shell_state)
          {shell_state, workspace}
        else
          {shell_state, workspace}
        end
    end
  end

  def handle_gui_action(shell_state, workspace, :agent_dismiss) do
    # Dismiss the agent: zoom out to the Board grid
    case shell_state.zoomed_into do
      nil ->
        {shell_state, workspace}

      card_id ->
        zoom_out_card(shell_state, workspace, card_id)
    end
  end

  def handle_gui_action(shell_state, workspace, _action) do
    {shell_state, workspace}
  end

  @impl true
  @spec compute_layout(term()) :: Minga.Editor.Layout.t()
  def compute_layout(editor_state) do
    if BoardState.grid_view?(editor_state.shell_state) do
      # TODO: Board grid layout computation
      Minga.Editor.Layout.compute(editor_state)
    else
      # Zoomed: use Traditional layout
      Minga.Editor.Layout.compute(editor_state)
    end
  end

  @impl true
  @spec build_chrome(term(), Minga.Editor.Layout.t(), map(), term()) ::
          Minga.Editor.RenderPipeline.Chrome.t()
  def build_chrome(editor_state, layout, scrolls, cursor_info) do
    chrome =
      Minga.Editor.RenderPipeline.Chrome.build_chrome(editor_state, layout, scrolls, cursor_info)

    if BoardState.grid_view?(editor_state.shell_state) do
      chrome
    else
      # Zoomed: inject context bar into the tab_bar chrome slot
      inject_zoom_context_bar(chrome, editor_state)
    end
  end

  @spec inject_zoom_context_bar(Minga.Editor.RenderPipeline.Chrome.t(), term()) ::
          Minga.Editor.RenderPipeline.Chrome.t()
  defp inject_zoom_context_bar(chrome, editor_state) do
    board = editor_state.shell_state
    card = BoardState.zoomed(board)
    cols = editor_state.workspace.viewport.cols
    theme = editor_state.theme

    if card do
      icon = zoom_status_icon(card.status)
      task = card.task || "Untitled"
      model = if card.model, do: " · #{card.model}", else: ""
      hint = "ESC back to Board"

      bg = theme.editor.bg
      bar_face = Minga.Core.Face.new(fg: theme.editor.fg, bg: bg, bold: true)
      hint_face = Minga.Core.Face.new(fg: 0x5C6370, bg: bg)
      status_face = zoom_status_face(card.status, theme)

      left = " #{icon} #{task}#{model}"
      right = " #{hint} "
      gap = max(cols - String.length(left) - String.length(right), 0)

      context_draws = [
        DisplayList.draw(0, 0, left, bar_face),
        DisplayList.draw(0, String.length(left), String.duplicate(" ", gap), status_face),
        DisplayList.draw(0, String.length(left) + gap, right, hint_face)
      ]

      # Replace the tab_bar draws with our context bar
      %{chrome | tab_bar: context_draws}
    else
      chrome
    end
  end

  @spec zoom_status_icon(Minga.Shell.Board.Card.status()) :: String.t()
  defp zoom_status_icon(:idle), do: "○"
  defp zoom_status_icon(:working), do: "●"
  defp zoom_status_icon(:iterating), do: "◉"
  defp zoom_status_icon(:needs_you), do: "◆"
  defp zoom_status_icon(:done), do: "✓"
  defp zoom_status_icon(:errored), do: "✗"
  defp zoom_status_icon(_), do: "○"

  @spec zoom_status_face(Minga.Shell.Board.Card.status(), Minga.UI.Theme.t()) ::
          Minga.Core.Face.t()
  defp zoom_status_face(:working, theme),
    do: Minga.Core.Face.new(fg: 0x98C379, bg: theme.editor.bg)

  defp zoom_status_face(:needs_you, theme),
    do: Minga.Core.Face.new(fg: 0xE5C07B, bg: theme.editor.bg)

  defp zoom_status_face(:done, theme), do: Minga.Core.Face.new(fg: 0x61AFEF, bg: theme.editor.bg)

  defp zoom_status_face(:errored, theme),
    do: Minga.Core.Face.new(fg: 0xE06C75, bg: theme.editor.bg)

  defp zoom_status_face(_, theme), do: Minga.Core.Face.new(fg: 0x5C6370, bg: theme.editor.bg)

  @impl true
  @spec render(term()) :: term()
  def render(editor_state) do
    if BoardState.grid_view?(editor_state.shell_state) do
      render_board_grid(editor_state)
    else
      # Zoomed into a card: dismiss the Board overlay on GUI,
      # then render the editor workspace normally.
      if Minga.Frontend.gui?(editor_state.capabilities) do
        # Send gui_board with visible=false to hide BoardView
        ctx = EmitContext.from_editor_state(editor_state)
        Minga.Frontend.Emit.GUI.sync_swiftui_chrome(ctx)
      end

      Minga.Editor.Renderer.render_buffer(editor_state)
    end
  end

  @spec render_board_grid(term()) :: term()
  defp render_board_grid(editor_state) do
    gui? = Minga.Frontend.gui?(editor_state.capabilities)

    if gui? do
      # GUI: send the gui_board opcode so Swift shows BoardView.
      # Also send chrome sync (status bar, theme, etc.).
      ctx = EmitContext.from_editor_state(editor_state)
      Minga.Frontend.Emit.GUI.sync_swiftui_chrome(ctx)
    else
      # TUI: render card grid as cell grid commands
      vp = editor_state.workspace.viewport
      board = editor_state.shell_state

      splash_draws =
        Minga.Shell.Board.Renderer.render(board, vp.cols, vp.rows, editor_state.theme)

      cursor = Cursor.new(0, 0, :block)

      frame = %Frame{
        cursor: cursor,
        splash: splash_draws,
        overlays: []
      }

      commands = DisplayList.to_commands(frame)
      Minga.Frontend.send_commands(editor_state.port_manager, commands)
    end

    editor_state
  end

  @impl true
  @spec input_handlers(term()) :: %{overlay: [module()], surface: [module()]}
  def input_handlers(editor_state) do
    if BoardState.grid_view?(editor_state.shell_state) do
      # Board grid: Board.Input handles navigation, zoom, dispatch.
      # GlobalBindings provides Ctrl+Q/Ctrl+S. Everything else passes through.
      %{
        overlay: Minga.Input.overlay_handlers(),
        surface: [
          Minga.Shell.Board.Input,
          Minga.Input.GlobalBindings
        ]
      }
    else
      # Zoomed into a card: full Traditional handler stack with
      # Board.ZoomOut prepended to intercept Escape for zoom-out.
      traditional_surface = Minga.Input.surface_handlers(editor_state)

      %{
        overlay: Minga.Input.overlay_handlers(),
        surface: [Minga.Shell.Board.ZoomOut | traditional_surface]
      }
    end
  end

  # Zoom out from a card: store the live workspace on the card, restore the grid workspace.
  @spec zoom_out_card(BoardState.t(), Minga.Workspace.State.t(), String.t()) ::
          {BoardState.t(), Minga.Workspace.State.t()}
  defp zoom_out_card(shell_state, workspace, card_id) do
    card = Map.get(shell_state.cards, card_id)

    if card do
      grid_workspace = card.workspace
      live_workspace = Map.from_struct(workspace)
      updated_card = Card.store_workspace(card, live_workspace)
      shell_state = %{shell_state | cards: Map.put(shell_state.cards, card_id, updated_card)}
      shell_state = %{shell_state | zoomed_into: nil}

      workspace = restore_grid_workspace(grid_workspace, workspace)

      Minga.Shell.Board.Persistence.save(shell_state)
      {shell_state, workspace}
    else
      {shell_state, workspace}
    end
  end

  @spec restore_grid_workspace(map() | nil, Minga.Workspace.State.t()) ::
          Minga.Workspace.State.t()
  defp restore_grid_workspace(grid_workspace, _fallback)
       when is_map(grid_workspace) and map_size(grid_workspace) > 0 do
    struct!(Minga.Workspace.State, grid_workspace)
  end

  defp restore_grid_workspace(_grid_workspace, fallback), do: fallback

  # Ensure a "You" card exists in restored board state (may have been removed in a bug).
  @spec ensure_you_card(BoardState.t()) :: BoardState.t()
  defp ensure_you_card(state) do
    has_you = Enum.any?(state.cards, fn {_id, c} -> c.kind == :you end)

    if has_you do
      state
    else
      {state, _you} = BoardState.create_card(state, task: "You", status: :idle, kind: :you)
      state
    end
  end
end
