defmodule MingaBoard.Shell do
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

  @behaviour MingaEditor.Shell
  @behaviour MingaEditor.Shell.Layout
  @behaviour MingaEditor.Shell.Chrome
  @behaviour MingaEditor.Shell.InputRouter
  @behaviour MingaEditor.Shell.BufferLifecycle
  @behaviour MingaEditor.Shell.TabQueries

  alias Minga.RenderModel.UI
  alias MingaAgent.Subagent.Handle
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, Frame}
  alias MingaEditor.RenderModel.UI.BoardBuilder
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.Renderer.Regions
  alias MingaEditor.Frontend.Protocol.GUI.BoardCardPayload
  alias MingaEditor.Frontend.Protocol.GUI.BoardPayload
  alias MingaBoard.AgentActivation
  alias MingaBoard.Shell.AgentDeactivation
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaBoard.Shell.Card
  alias MingaBoard.Shell.SessionLifecycle
  alias MingaBoard.Shell.State, as: BoardState
  alias MingaEditor.Session.State, as: SessionState

  @impl true
  @spec init(keyword()) :: MingaEditor.Shell.shell_state()
  def init(opts \\ []) do
    # Try to restore persisted board state from disk (skip in test env)
    skip_persistence = Keyword.get(opts, :skip_persistence, false)

    case if(skip_persistence, do: nil, else: MingaBoard.Shell.Persistence.load()) do
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
  @spec handle_event(BoardState.t(), MingaEditor.Session.State.t(), term()) ::
          {BoardState.t(), MingaEditor.Session.State.t()}
  def handle_event(shell_state, workspace, {:background_subagent_started, %Handle{} = handle}) do
    if card_for_session?(shell_state, handle.pid) do
      {shell_state, workspace}
    else
      {shell_state, card} =
        BoardState.create_card(shell_state,
          task: Handle.label(handle),
          model: handle.model,
          status: :working,
          kind: :agent,
          session: handle.pid,
          workspace: SessionState.to_tab_context(workspace)
        )

      Minga.Log.info(
        :agent,
        "Board: added background sub-agent card ##{card.id}: #{Handle.label(handle)}"
      )

      MingaBoard.Shell.Persistence.save(shell_state)
      {shell_state, workspace}
    end
  end

  def handle_event(shell_state, workspace, _event) do
    {shell_state, workspace}
  end

  @impl true
  @spec handle_gui_action(BoardState.t(), MingaEditor.Session.State.t(), term()) ::
          {BoardState.t(), MingaEditor.Session.State.t()}
  def handle_gui_action(shell_state, workspace, {:board_select_card, card_id}) do
    case Map.fetch(shell_state.cards, card_id) do
      {:ok, card} ->
        # GUI card click: focus, zoom in, activate agent view.
        # Same logic as Board.Input's Enter key handler.
        shell_state = BoardState.focus_card(shell_state, card_id)
        workspace_snapshot = SessionState.to_tab_context(workspace)
        shell_state = BoardState.zoom_into(shell_state, card_id, workspace_snapshot)
        workspace = restore_workspace(card.workspace, workspace)

        # Agent activation (session, scope, window content, prompt focus) is handled by `after_gui_action/2` after this function returns. The Shell behaviour only has (shell_state, workspace) access here; full EditorState is needed for session attachment.

        {shell_state, workspace}

      :error ->
        Minga.Log.warning(:agent, "Board: ignored stale GUI card selection #{inspect(card_id)}")
        {shell_state, workspace}
    end
  end

  def handle_gui_action(shell_state, workspace, {:board_close_card, card_id}) do
    case Map.fetch(shell_state.cards, card_id) do
      {:ok, card} ->
        handle_close_card(shell_state, workspace, card_id, card)

      :error ->
        Minga.Log.warning(:agent, "Board: ignored stale GUI card close #{inspect(card_id)}")
        {BoardState.set_status(shell_state, "Board card is unavailable"), workspace}
    end
  end

  def handle_gui_action(shell_state, workspace, {:board_reorder, card_id, new_index}) do
    case Map.fetch(shell_state.cards, card_id) do
      {:ok, _card} ->
        shell_state = BoardState.reorder_card(shell_state, card_id, new_index)
        MingaBoard.Shell.Persistence.save(shell_state)
        {shell_state, workspace}

      :error ->
        Minga.Log.warning(:agent, "Board: ignored stale GUI card reorder #{inspect(card_id)}")
        {BoardState.set_status(shell_state, "Board card is unavailable"), workspace}
    end
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

    opts = [provider_opts: [model: model], thinking_level: "medium"]

    case SessionLifecycle.start(opts) do
      {:ok, pid} ->
        shell_state = BoardState.update_card(shell_state, card.id, &Card.attach_session(&1, pid))
        MingaBoard.Shell.Persistence.save(shell_state)
        {shell_state, workspace}

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Board: failed to start session for card ##{card.id}: #{inspect(reason)}"
        )

        shell_state = BoardState.update_card(shell_state, card.id, &Card.set_status(&1, :errored))
        MingaBoard.Shell.Persistence.save(shell_state)
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
          shell_state = BoardState.set_card_status(shell_state, card_id, :done)
          MingaBoard.Shell.Persistence.save(shell_state)
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
          shell_state = BoardState.set_card_status(shell_state, card_id, :needs_you)
          MingaBoard.Shell.Persistence.save(shell_state)
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

  @spec handle_close_card(BoardState.t(), SessionState.t(), Card.id(), Card.t()) ::
          {BoardState.t(), SessionState.t()}
  defp handle_close_card(shell_state, workspace, card_id, card) do
    case close_card(shell_state, card) do
      {:ok, shell_state} ->
        MingaBoard.Shell.Persistence.save(shell_state)
        {shell_state, workspace}

      {:error, :you_card} ->
        Minga.Log.warning(:agent, "Board: ignored request to close required You card")
        {shell_state, workspace}

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Board: failed to stop session for card #{inspect(card_id)}: #{inspect(reason)}"
        )

        shell_state = BoardState.set_card_status(shell_state, card_id, :errored)
        {shell_state, workspace}
    end
  end

  @impl true
  @spec after_gui_action(MingaEditor.State.t(), term()) :: MingaEditor.State.t()
  def after_gui_action(state, :agent_dismiss) do
    AgentDeactivation.deactivate_agent_for_card(state)
  end

  def after_gui_action(state, {:board_dispatch_agent, _task, _model}) do
    case BoardState.focused(state.shell_state) do
      %Card{status: :errored} ->
        EditorState.set_status(state, "Could not start Board agent session")

      _card ->
        state
    end
  end

  def after_gui_action(state, {:board_select_card, card_id}) do
    case Map.fetch(state.shell_state.cards, card_id) do
      {:ok, card} ->
        state = restore_first_zoom_agent_workspace(state, card)
        {new_board, state} = SessionLifecycle.ensure_session(state.shell_state, card, state)
        state = EditorState.update_shell_state(state, fn _ -> new_board end)
        card = new_board.cards[card_id]
        activate_selected_card(state, card)

      :error ->
        Minga.Log.warning(
          :agent,
          "Board: selected card #{inspect(card_id)} is no longer available"
        )

        EditorState.set_status(state, "Board card is unavailable")
    end
  end

  def after_gui_action(state, _action), do: state

  @impl true
  @spec compute_layout(term()) :: MingaEditor.Layout.t()
  def compute_layout(editor_state) do
    if MingaEditor.Frontend.gui?(editor_state.capabilities) do
      # GUI: Metal viewport is the full editor area, no shell chrome rects
      MingaEditor.Layout.GUI.compute(editor_state)
    else
      compute_board_tui_layout(editor_state)
    end
  end

  # Board TUI layout: no tab bar, no file tree, no modeline.
  # Grid view uses the full viewport. Zoomed view reserves row 0
  # for the context bar and the last row for the minibuffer.
  @spec compute_board_tui_layout(term()) :: MingaEditor.Layout.t()
  defp compute_board_tui_layout(editor_state) do
    alias MingaEditor.Layout
    vp = editor_state.terminal_viewport
    {rows, cols} = {vp.rows, vp.cols}

    if BoardState.grid_view?(editor_state.shell_state) do
      # Grid: full viewport as editor_area, 1-row minibuffer at bottom
      editor_rows = max(rows - 1, 1)

      %Layout{
        terminal: {0, 0, cols, rows},
        editor_area: {0, 0, cols, editor_rows},
        minibuffer: {editor_rows, 0, cols, 1}
      }
    else
      # Zoomed: row 0 = context bar, last row = minibuffer, rest = editor
      context_bar_height = 1
      minibuffer_height = 1
      editor_rows = max(rows - context_bar_height - minibuffer_height, 1)
      editor_top = context_bar_height

      {window_layouts, h_seps} =
        Layout.compute_window_layouts_with_separators(
          editor_state.workspace.windows.tree,
          {editor_top, 0, cols, editor_rows},
          editor_state.workspace.windows.map
        )

      %Layout{
        terminal: {0, 0, cols, rows},
        editor_area: {editor_top, 0, cols, editor_rows},
        window_layouts: window_layouts,
        horizontal_separators: h_seps,
        minibuffer: {editor_top + editor_rows, 0, cols, minibuffer_height}
      }
    end
  end

  @impl true
  @spec build_chrome(term(), MingaEditor.Layout.t(), map(), term()) ::
          Chrome.t()
  def build_chrome(editor_state, layout, _scrolls, _cursor_info) do
    if BoardState.grid_view?(editor_state.shell_state) do
      # Grid view: BoardView overlay handles everything, empty chrome
      %Chrome{}
    else
      # Zoomed: context bar in tab_bar slot, everything else empty
      context_draws = build_zoom_context_bar(editor_state)
      regions = Regions.define_regions(layout)
      %Chrome{tab_bar: context_draws, regions: regions}
    end
  end

  @spec build_zoom_context_bar(term()) :: [DisplayList.draw()]
  defp build_zoom_context_bar(editor_state) do
    board = editor_state.shell_state
    card = BoardState.zoomed(board)
    cols = editor_state.terminal_viewport.cols
    theme = editor_state.theme

    if card do
      icon = zoom_status_icon(card.status)
      task = MingaBoard.Shell.Card.display_task(card)
      model = if card.model, do: " · #{card.model}", else: ""
      hint = "ESC back to Board"

      bg = theme.editor.bg
      bar_face = Minga.Core.Face.new(fg: theme.editor.fg, bg: bg, bold: true)
      hint_face = Minga.Core.Face.new(fg: 0x5C6370, bg: bg)
      status_face = zoom_status_face(card.status, theme)

      left = " #{icon} #{task}#{model}"
      right = " #{hint} "
      gap = max(cols - String.length(left) - String.length(right), 0)

      [
        DisplayList.draw(0, 0, left, bar_face),
        DisplayList.draw(0, String.length(left), String.duplicate(" ", gap), status_face),
        DisplayList.draw(0, String.length(left) + gap, right, hint_face)
      ]
    else
      []
    end
  end

  @spec zoom_status_icon(MingaBoard.Shell.Card.status()) :: String.t()
  defp zoom_status_icon(:idle), do: "○"
  defp zoom_status_icon(:working), do: "●"
  defp zoom_status_icon(:iterating), do: "◉"
  defp zoom_status_icon(:needs_you), do: "◆"
  defp zoom_status_icon(:done), do: "✓"
  defp zoom_status_icon(:errored), do: "✗"

  @spec zoom_status_face(MingaBoard.Shell.Card.status(), MingaEditor.UI.Theme.t()) ::
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
  @spec chrome_fingerprint(term()) :: term()
  def chrome_fingerprint(_editor_state), do: nil

  @impl true
  @spec async_render?(term()) :: boolean()
  def async_render?(%{
        shell_state: %BoardState{} = board_state,
        workspace: %{buffers: %{active: active}}
      }) do
    not BoardState.grid_view?(board_state) and is_pid(active)
  end

  @impl true
  @spec gui_payload(term()) :: {:board, BoardPayload.t()}
  def gui_payload(%{shell_state: %BoardState{} = board}), do: {:board, board_payload(board)}

  @spec board_payload(BoardState.t()) :: BoardPayload.t()
  defp board_payload(%BoardState{} = board) do
    %BoardPayload{
      visible?: BoardState.grid_view?(board),
      focused_card_id: board.focused_card,
      zoomed_card_id: board.zoomed_into,
      filter_mode?: board.filter_mode,
      filter_text: board.filter_text,
      cards: Enum.map(BoardState.sorted_cards(board), &card_payload/1)
    }
  end

  @spec card_payload(Card.t()) :: BoardCardPayload.t()
  defp card_payload(%Card{} = card) do
    %BoardCardPayload{
      id: card.id,
      status: card.status,
      kind: card.kind,
      task: card.task,
      display_task: Card.display_task(card),
      model: card.model,
      created_at: card.created_at,
      recent_files: card.recent_files,
      sparkline: card.sparkline
    }
  end

  @impl true
  @spec render(term()) :: term()
  def render(editor_state) do
    if BoardState.grid_view?(editor_state.shell_state) do
      render_board_grid(editor_state)
    else
      # Zoomed into a card: render_buffer runs the full pipeline, including the core GUI adapter when a GUI frontend is active, so no explicit chrome call is needed here.
      MingaEditor.Renderer.render_buffer(editor_state)
    end
  end

  @spec render_board_grid(term()) :: term()
  defp render_board_grid(editor_state) do
    gui? = MingaEditor.Frontend.gui?(editor_state.capabilities)

    if gui? do
      # GUI: send the gui_board opcode so Swift shows BoardView.
      # Thread caches so fingerprint-based skipping works across frames.
      ui = %UI{board: BoardBuilder.build(gui_payload(editor_state))}

      {chrome_cmds, adapter_caches} =
        Minga.Frontend.Adapter.GUI.encode_ui(ui, editor_state.caches.adapter_gui_caches)

      if chrome_cmds != [] do
        MingaEditor.Frontend.send_commands(editor_state.port_manager, chrome_cmds)
      end

      new_caches = %{editor_state.caches | adapter_gui_caches: adapter_caches}
      %{editor_state | caches: new_caches}
    else
      # TUI: render card grid as cell grid commands
      vp = editor_state.terminal_viewport
      board = editor_state.shell_state

      splash_draws =
        MingaBoard.Shell.Renderer.render(board, vp.cols, vp.rows, editor_state.theme)

      cursor = Cursor.new(0, 0, :block)

      frame = %Frame{
        cursor: cursor,
        splash: splash_draws,
        overlays: []
      }

      commands = DisplayList.to_commands(frame)
      MingaEditor.Frontend.send_commands(editor_state.port_manager, commands)
      editor_state
    end
  end

  @impl true
  @spec input_handlers(term()) :: %{overlay: [module()], surface: [module()]}
  def input_handlers(editor_state) do
    if BoardState.grid_view?(editor_state.shell_state) do
      # Board grid: Board.Input handles navigation, zoom, dispatch.
      # GlobalBindings provides Ctrl+Q/Ctrl+S. Everything else passes through.
      %{
        overlay: MingaEditor.Input.overlay_handlers(),
        surface: [
          MingaBoard.Shell.Input,
          MingaEditor.Input.GlobalBindings
        ]
      }
    else
      # Zoomed into a card: full Traditional handler stack with
      # Board.ZoomOut prepended to intercept Escape for zoom-out.
      traditional_surface = MingaEditor.Input.surface_handlers(editor_state)

      %{
        overlay: MingaEditor.Input.overlay_handlers(),
        surface: [MingaBoard.Shell.ZoomOut | traditional_surface]
      }
    end
  end

  # -------------------------------------------------------------------
  # Buffer lifecycle callbacks
  # -------------------------------------------------------------------

  @impl true
  @spec on_buffer_added(
          BoardState.t(),
          MingaEditor.Session.State.t(),
          MingaEditor.Session.State.t(),
          pid(),
          atom()
        ) :: {BoardState.t(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_buffer_added(shell_state, _prev_workspace, workspace, _buffer_pid, _context) do
    # Board: sync the active window buffer. A1's content-type guard
    # ensures agent_chat windows are left untouched.
    workspace = MingaEditor.Session.State.sync_active_window_buffer(workspace)
    {shell_state, workspace, []}
  end

  @spec on_buffer_added(BoardState.t(), MingaEditor.Session.State.t(), pid(), atom()) ::
          {BoardState.t(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_buffer_added(shell_state, workspace, buffer_pid, context \\ :open) do
    on_buffer_added(shell_state, workspace, workspace, buffer_pid, context)
  end

  @impl true
  @spec on_buffer_switched(BoardState.t(), MingaEditor.Session.State.t()) ::
          {BoardState.t(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_buffer_switched(shell_state, workspace) do
    {shell_state, workspace, []}
  end

  @impl true
  @spec on_buffer_died(BoardState.t(), MingaEditor.Session.State.t(), pid()) ::
          {BoardState.t(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_buffer_died(shell_state, workspace, _dead_pid) do
    # Board: sync the window if it's showing a buffer. The content-type
    # guard in sync_active_window_buffer ensures agent_chat is untouched.
    workspace = MingaEditor.Session.State.sync_active_window_buffer(workspace)
    {shell_state, workspace, []}
  end

  # -------------------------------------------------------------------
  # Tab query/mutation delegates
  # -------------------------------------------------------------------

  @impl true
  @spec active_tab(BoardState.t()) :: nil
  def active_tab(_shell_state), do: nil

  @impl true
  @spec find_tab_by_buffer(BoardState.t(), pid()) :: nil
  def find_tab_by_buffer(_shell_state, _pid), do: nil

  @impl true
  @spec active_tab_kind(BoardState.t()) :: atom()
  def active_tab_kind(_shell_state), do: :file

  @impl true
  @spec set_tab_session(BoardState.t(), term(), pid() | nil) :: BoardState.t()
  def set_tab_session(shell_state, _tab_id, _session_pid), do: shell_state

  @doc "Persists Board shell state when host-level lifecycle callbacks mutate it."
  @spec persist_shell_state(BoardState.t()) :: BoardState.t()
  def persist_shell_state(%BoardState{} = shell_state) do
    MingaBoard.Shell.Persistence.save(shell_state)
    shell_state
  end

  @doc "Updates a card after its agent session exits."
  @spec handle_agent_session_down(BoardState.t(), pid(), term()) :: {BoardState.t(), boolean()}
  def handle_agent_session_down(%BoardState{} = shell_state, session_pid, reason) do
    card_status = if reason in [:normal, :shutdown], do: :done, else: :errored

    case Enum.find(shell_state.cards, fn {_id, card} -> card.session == session_pid end) do
      {card_id, _card} ->
        board =
          BoardState.update_card(shell_state, card_id, fn card ->
            card
            |> Card.set_status(card_status)
            |> Card.detach_session()
          end)

        {board, true}

      nil ->
        {shell_state, false}
    end
  end

  @doc "Marks a card's remote agent connection as disconnected."
  @spec handle_remote_session_disconnected(BoardState.t(), pid()) :: {BoardState.t(), boolean()}
  def handle_remote_session_disconnected(%BoardState{} = shell_state, session_pid) do
    case Enum.find(shell_state.cards, fn {_id, card} -> card.session == session_pid end) do
      {card_id, _card} ->
        board =
          BoardState.update_card(
            shell_state,
            card_id,
            &Card.set_connection_status(&1, :disconnected)
          )

        {board, true}

      nil ->
        {shell_state, false}
    end
  end

  @doc "Syncs a card status from the associated agent session."
  @spec sync_agent_status(BoardState.t(), pid(), atom()) :: BoardState.t()
  def sync_agent_status(%BoardState{} = shell_state, session_pid, status) do
    card_status = Card.from_agent_status(status)
    update_card_by_session(shell_state, session_pid, &Card.set_status(&1, card_status))
  end

  @doc "Tracks a recently touched file on the card associated with an agent session."
  @spec track_agent_file(BoardState.t(), pid(), String.t()) :: BoardState.t()
  def track_agent_file(%BoardState{} = shell_state, session_pid, path) do
    short_path = Path.basename(path)

    update_card_by_session(shell_state, session_pid, fn card ->
      files = [short_path | Enum.reject(card.recent_files, &(&1 == short_path))]
      Card.set_recent_files(card, Enum.take(files, 5))
    end)
  end

  @doc "Drops feature state owned by a source from all Board card workspace snapshots."
  @spec drop_feature_state_source(BoardState.t(), MingaEditor.FeatureState.source()) ::
          BoardState.t()
  def drop_feature_state_source(%BoardState{} = shell_state, source) do
    BoardState.drop_feature_state_source(shell_state, source)
  end

  @doc "Drops extension-owned feature state from all Board card workspace snapshots."
  @spec drop_extension_feature_state_sources(BoardState.t()) :: BoardState.t()
  def drop_extension_feature_state_sources(%BoardState{} = shell_state) do
    BoardState.drop_extension_feature_state_sources(shell_state)
  end

  @impl true
  @spec active_session(BoardState.t()) :: pid() | nil
  def active_session(%BoardState{} = shell_state) do
    case BoardState.zoomed(shell_state) do
      %Card{session: pid} -> pid
      _ -> nil
    end
  end

  # -------------------------------------------------------------------
  # Agent event callbacks
  # -------------------------------------------------------------------

  @impl true
  @spec on_agent_event(BoardState.t(), MingaEditor.Session.State.t(), pid(), term()) ::
          {BoardState.t(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_agent_event(shell_state, workspace, session_pid, {:status_changed, status}) do
    card_status = Card.from_agent_status(status)

    shell_state =
      update_card_by_session(shell_state, session_pid, &Card.set_status(&1, card_status))

    {shell_state, workspace, []}
  end

  # Cards have no separate attention flag; status :needs_you carries the alert.
  def on_agent_event(shell_state, workspace, session_pid, {:approval_pending, _}) do
    shell_state =
      update_card_by_session(shell_state, session_pid, &Card.set_status(&1, :needs_you))

    {shell_state, workspace, []}
  end

  def on_agent_event(shell_state, workspace, session_pid, {:error, _message}) do
    shell_state =
      update_card_by_session(shell_state, session_pid, &Card.set_status(&1, :errored))

    {shell_state, workspace, []}
  end

  def on_agent_event(
        shell_state,
        workspace,
        session_pid,
        {:file_changed, path, _before_content, _after_content, _tool_call_id, _tool_name}
      ) do
    shell_state = track_agent_file(shell_state, session_pid, path)
    {shell_state, workspace, []}
  end

  def on_agent_event(shell_state, workspace, _session_pid, _event) do
    {shell_state, workspace, []}
  end

  @spec close_card(BoardState.t(), Card.t() | nil) :: {:ok, BoardState.t()} | {:error, term()}
  defp close_card(%BoardState{} = shell_state, nil), do: {:ok, shell_state}

  defp close_card(%BoardState{} = shell_state, %Card{} = card) do
    case Card.you_card?(card) do
      true ->
        {:error, :you_card}

      false ->
        case SessionLifecycle.stop(card.session) do
          :ok -> {:ok, BoardState.remove_card(shell_state, card.id)}
          {:error, _reason} = error -> error
        end
    end
  end

  @spec card_for_session?(BoardState.t(), pid()) :: boolean()
  defp card_for_session?(shell_state, session_pid) when is_pid(session_pid) do
    Enum.any?(shell_state.cards, fn {_id, card} -> card.session == session_pid end)
  end

  @spec update_card_by_session(BoardState.t(), pid(), (Card.t() -> Card.t())) :: BoardState.t()
  defp update_card_by_session(shell_state, session_pid, fun) do
    case Enum.find(shell_state.cards, fn {_id, c} -> c.session == session_pid end) do
      {card_id, _card} ->
        BoardState.update_card(shell_state, card_id, fun)

      nil ->
        shell_state
    end
  end

  # Zoom out from a card: store the live workspace on the card, restore the grid workspace.
  @spec zoom_out_card(BoardState.t(), MingaEditor.Session.State.t(), String.t()) ::
          {BoardState.t(), MingaEditor.Session.State.t()}
  defp zoom_out_card(shell_state, workspace, card_id) do
    card = Map.get(shell_state.cards, card_id)

    if card do
      live_workspace = SessionState.to_tab_context(workspace)

      {shell_state, grid_workspace} =
        BoardState.store_live_workspace_and_zoom_out(shell_state, card_id, live_workspace)

      workspace = restore_workspace(grid_workspace, workspace)

      MingaBoard.Shell.Persistence.save(shell_state)
      {shell_state, workspace}
    else
      {shell_state, workspace}
    end
  end

  @spec activate_selected_card(EditorState.t(), Card.t() | nil) :: EditorState.t()
  defp activate_selected_card(%EditorState{} = state, %Card{kind: :agent, session: nil} = card) do
    live_workspace = SessionState.to_tab_context(state.workspace)

    {board, grid_workspace} =
      BoardState.store_live_workspace_and_zoom_out(state.shell_state, card.id, live_workspace)

    state
    |> EditorState.update_shell_state(fn _ -> board end)
    |> restore_grid_workspace(grid_workspace)
    |> EditorState.set_status("Could not start Board agent session")
  end

  defp activate_selected_card(%EditorState{} = state, card) do
    AgentActivation.activate_for_card(state, card)
  end

  @spec restore_grid_workspace(EditorState.t(), Card.workspace_snapshot() | nil) ::
          EditorState.t()
  defp restore_grid_workspace(%EditorState{} = state, nil), do: state

  defp restore_grid_workspace(%EditorState{} = state, workspace),
    do: EditorState.restore_tab_context(state, workspace)

  @spec restore_first_zoom_agent_workspace(EditorState.t(), Card.t()) :: EditorState.t()
  defp restore_first_zoom_agent_workspace(%EditorState{} = state, %Card{kind: :agent} = card) do
    if agent_workspace_active?(state) or restored_card_workspace?(state.workspace, card.workspace) do
      state
    else
      agent_buf = AgentAccess.agent(state).buffer
      fresh_context = EditorState.build_agent_workspace_context(state, agent_buf)
      EditorState.restore_tab_context(state, fresh_context)
    end
  end

  defp restore_first_zoom_agent_workspace(%EditorState{} = state, %Card{}), do: state

  @spec restored_card_workspace?(SessionState.t(), Card.workspace_snapshot() | nil) :: boolean()
  defp restored_card_workspace?(%SessionState{} = workspace, card_workspace)
       when not is_nil(card_workspace) do
    SessionState.to_tab_context(workspace) != card_workspace
  end

  defp restored_card_workspace?(%SessionState{}, nil), do: false

  @spec agent_workspace_active?(EditorState.t()) :: boolean()
  defp agent_workspace_active?(%EditorState{} = state) do
    case EditorState.active_window_struct(state) do
      %{content: {:agent_chat, _session}} -> state.workspace.keymap_scope == :agent
      _ -> false
    end
  end

  @spec restore_workspace(Card.workspace_snapshot() | nil, MingaEditor.Session.State.t()) ::
          MingaEditor.Session.State.t()
  defp restore_workspace(workspace_snapshot, fallback)
       when is_map(workspace_snapshot) and map_size(workspace_snapshot) > 0 do
    SessionState.restore_tab_context(fallback, workspace_snapshot)
  end

  defp restore_workspace(_workspace_snapshot, fallback), do: fallback

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
