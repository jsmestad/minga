defmodule MingaEditor.RenderPipeline.Scroll do
  @moduledoc """
  Stage 3: Scroll.

  Applies the pre-fetched per-window scroll snapshots to the render input without reaching across process boundaries. Buffer GenServer reads happen before the staged pipeline in `MingaEditor.RenderPipeline.BufferPrefetch`; this stage is a pure handoff that preserves the documented seven-stage render contract.
  """

  alias MingaEditor.FoldMap.VisibleLines
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  defmodule WindowScroll do
    @moduledoc """
    Per-window data consumed by the pure scroll and content stages.

    Bundles the viewport, buffer snapshot, cursor positions, gutter dimensions, buffer options, and pre-fetched signs for one window. Downstream render stages consume this struct instead of making GenServer calls.
    """

    alias MingaEditor.FoldMap.VisibleLines
    alias MingaEditor.Layout
    alias MingaEditor.Viewport
    alias MingaEditor.Window

    @enforce_keys [
      :win_id,
      :window,
      :win_layout,
      :is_active,
      :viewport,
      :cursor_line,
      :cursor_byte_col,
      :cursor_col,
      :first_line,
      :lines,
      :snapshot,
      :gutter_w,
      :content_w,
      :has_sign_column,
      :preview_matches,
      :line_number_style,
      :wrap_on,
      :buf_version,
      :width_oracle
    ]

    defstruct [
      :win_id,
      :window,
      :win_layout,
      :is_active,
      :viewport,
      :cursor_line,
      :cursor_byte_col,
      :cursor_col,
      :first_line,
      :lines,
      :snapshot,
      :gutter_w,
      :content_w,
      :has_sign_column,
      :preview_matches,
      :line_number_style,
      :wrap_on,
      :buf_version,
      :width_oracle,
      git_signs: %{},
      visible_line_map: nil
    ]

    @type t :: %__MODULE__{
            win_id: Window.id(),
            window: Window.t(),
            win_layout: Layout.window_layout(),
            is_active: boolean(),
            viewport: Viewport.t(),
            cursor_line: non_neg_integer(),
            cursor_byte_col: non_neg_integer(),
            cursor_col: non_neg_integer(),
            first_line: non_neg_integer(),
            lines: [String.t()],
            snapshot: Minga.Buffer.RenderSnapshot.t(),
            gutter_w: non_neg_integer(),
            content_w: pos_integer(),
            has_sign_column: boolean(),
            preview_matches: list(),
            line_number_style: atom(),
            wrap_on: boolean(),
            buf_version: non_neg_integer(),
            width_oracle: Minga.Core.WidthOracle.t(),
            git_signs: %{non_neg_integer() => atom()},
            visible_line_map: [VisibleLines.line_entry()] | [MingaEditor.DisplayMap.entry()] | nil
          }
  end

  @typedoc "Render pipeline input."
  @type state :: Input.t()

  @doc """
  Returns the pre-fetched window scroll data for Stage 3.

  `prefetched_scrolls` is produced before the staged pipeline starts, so this function performs no GenServer calls.
  """
  @spec scroll_windows(state(), Layout.t(), %{Window.id() => WindowScroll.t()}) ::
          {%{Window.id() => WindowScroll.t()}, state()}
  def scroll_windows(%Input{} = input, _layout, prefetched_scrolls)
      when is_map(prefetched_scrolls) do
    {prefetched_scrolls, input}
  end

  @doc """
  Compatibility wrapper for tests and older direct callers.

  Production rendering uses `scroll_windows/3` with pre-fetched data so the scroll stage stays pure.
  """
  @spec scroll_windows(state() | MingaEditor.State.t(), Layout.t()) ::
          {%{Window.id() => WindowScroll.t()}, state()}
  def scroll_windows(%Input{} = input, %Layout{} = layout) do
    BufferPrefetch.prefetch_scrolls(input, layout)
  end

  def scroll_windows(%MingaEditor.State{} = state, %Layout{} = layout) do
    input = Input.from_editor_state(state)
    {scrolls, output} = BufferPrefetch.prefetch_scrolls(input, layout)
    {scrolls, MingaEditor.State.apply_render_output(state, output)}
  end
end
