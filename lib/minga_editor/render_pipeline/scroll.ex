defmodule MingaEditor.RenderPipeline.Scroll do
  @moduledoc """
  Stage 3: Scroll.

  Applies the pre-fetched per-window scroll snapshots to the render input without reaching across process boundaries. Buffer GenServer reads happen before the staged pipeline in `MingaEditor.RenderPipeline.BufferPrefetch`; this stage is a pure handoff that preserves the documented seven-stage render contract.
  """

  alias MingaEditor.FoldMap.VisibleLines
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Viewport
  alias MingaEditor.Renderer.RenderWindow, as: Window

  defmodule WindowScroll do
    @moduledoc """
    Per-window data consumed by the pure scroll and content stages.

    Bundles the viewport, buffer snapshot, cursor positions, gutter dimensions, buffer options, and pre-fetched signs for one window. Downstream render stages consume this struct instead of making GenServer calls.
    """

    alias MingaEditor.FoldMap.VisibleLines
    alias MingaEditor.Layout
    alias MingaEditor.Viewport
    alias MingaEditor.Renderer.RenderWindow, as: Window

    @enforce_keys [
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
      :width_oracle
    ]

    defstruct [
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
      :width_oracle,
      git_signs: %{},
      visible_line_map: nil,
      total_visual_rows: nil,
      visible_row_start_index: 0,
      content_epoch: 0,
      full_refresh: true,
      full_residence: false,
      scroll_seq: 0,
      line_identity: nil
    ]

    @type t :: %__MODULE__{
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
            width_oracle: Minga.Core.WidthOracle.t(),
            git_signs: %{non_neg_integer() => atom()},
            visible_line_map:
              [VisibleLines.line_entry()] | [MingaEditor.DisplayMap.entry()] | nil,
            total_visual_rows: non_neg_integer() | nil,
            visible_row_start_index: non_neg_integer(),
            content_epoch: non_neg_integer(),
            full_refresh: boolean(),
            full_residence: boolean(),
            scroll_seq: non_neg_integer(),
            line_identity: Minga.RenderModel.Window.LineIdentity.t() | nil
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
end
