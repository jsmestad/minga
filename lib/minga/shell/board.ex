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

  alias Minga.Shell.Board.State, as: BoardState

  @impl true
  @spec init(keyword()) :: Minga.Shell.shell_state()
  def init(opts \\ []) do
    state = BoardState.new()

    # Create the "You" card (manual editing, no agent session)
    {state, _you_card} = BoardState.create_card(state, task: "You", status: :idle)

    # If initial cards were passed (e.g., restored from session), add them
    Enum.reduce(Keyword.get(opts, :cards, []), state, fn card_attrs, acc ->
      {acc, _card} = BoardState.create_card(acc, card_attrs)
      acc
    end)
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
  def handle_gui_action(shell_state, workspace, _action) do
    # TODO: handle card clicks, zoom gestures from GUI
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
    if BoardState.grid_view?(editor_state.shell_state) do
      # TODO: Board grid chrome (card rectangles)
      Minga.Editor.RenderPipeline.Chrome.build_chrome(editor_state, layout, scrolls, cursor_info)
    else
      # Zoomed: use Traditional chrome
      Minga.Editor.RenderPipeline.Chrome.build_chrome(editor_state, layout, scrolls, cursor_info)
    end
  end

  @impl true
  @spec render(term()) :: term()
  def render(editor_state) do
    if BoardState.grid_view?(editor_state.shell_state) do
      # TODO: Board grid rendering
      # For now, render the dashboard (empty buffer state)
      Minga.Editor.Renderer.render_dashboard(editor_state)
    else
      # Zoomed: render the active card's workspace
      Minga.Editor.Renderer.render_buffer(editor_state)
    end
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
end
