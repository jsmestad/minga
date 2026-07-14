defmodule MingaEditor.State.Render do
  @moduledoc """
  Editor-owned render orchestration state.

  This value owns the renderer connection, render correlation, semantic message
  store, and layout observations committed from one editor revision. Renderer
  process caches remain owned by `MingaEditor.Renderer.Server`.
  """

  alias MingaEditor.FocusTree
  alias MingaEditor.Layout
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.UI.Panel.MessageStore

  @type t :: %__MODULE__{
          renderer: pid() | nil,
          render_correlation: RenderCorrelation.t(),
          message_store: MessageStore.t(),
          layout: Layout.t() | nil,
          focus_tree: FocusTree.t() | nil,
          last_cursor_line: non_neg_integer() | nil
        }

  defstruct renderer: nil,
            render_correlation: RenderCorrelation.new(),
            message_store: %MessageStore{},
            layout: nil,
            focus_tree: nil,
            last_cursor_line: nil

  @doc "Creates render state with a fresh semantic message store."
  @spec new() :: t()
  def new, do: %__MODULE__{message_store: MessageStore.new()}

  @doc "Records the renderer process currently serving this editor."
  @spec connect_renderer(t(), pid() | nil) :: t()
  def connect_renderer(%__MODULE__{} = render, renderer)
      when is_pid(renderer) or is_nil(renderer),
      do: %{render | renderer: renderer}

  @doc "Commits correlation state produced by a render scheduling transition."
  @spec accept_correlation(t(), RenderCorrelation.t()) :: t()
  def accept_correlation(%__MODULE__{} = render, %RenderCorrelation{} = correlation),
    do: %{render | render_correlation: correlation}

  @doc "Appends a structured editor log message to the semantic message store."
  @spec append_message(t(), String.t(), MessageStore.level(), atom() | nil) :: t()
  def append_message(%__MODULE__{} = render, text, level, subsystem) do
    message_store = MessageStore.append(render.message_store, text, level, subsystem)
    %{render | message_store: message_store}
  end

  @doc "Commits a semantic message store transition."
  @spec accept_message_store(t(), MessageStore.t()) :: t()
  def accept_message_store(%__MODULE__{} = render, %MessageStore{} = message_store),
    do: %{render | message_store: message_store}

  @doc "Stages a layout while its focus tree is derived from the full editor state."
  @spec stage_layout(t(), Layout.t()) :: t()
  def stage_layout(%__MODULE__{} = render, %Layout{} = layout),
    do: %{render | layout: layout, focus_tree: nil}

  @doc "Commits layout and focus observations derived from the same editor revision."
  @spec cache_layout(t(), Layout.t() | nil, FocusTree.t() | nil) :: t()
  def cache_layout(%__MODULE__{} = render, layout, focus_tree)
      when (is_struct(layout, Layout) or is_nil(layout)) and
             (is_struct(focus_tree, FocusTree.Node) or is_nil(focus_tree)),
      do: %{render | layout: layout, focus_tree: focus_tree}

  @doc "Invalidates layout observations after a shell transition."
  @spec invalidate_layout(t()) :: t()
  def invalidate_layout(%__MODULE__{} = render), do: %{render | layout: nil, focus_tree: nil}

  @doc "Remembers the last cursor line included in frontend presentation."
  @spec observe_cursor_line(t(), non_neg_integer() | nil) :: t()
  def observe_cursor_line(%__MODULE__{} = render, line)
      when is_nil(line) or (is_integer(line) and line >= 0),
      do: %{render | last_cursor_line: line}
end
