defmodule MingaEditor.Shell.Board.Layout do
  @moduledoc """
  Card grid layout computation for The Board.

  Computes card rectangles using the golden ratio (φ ≈ 1.618) for
  visually harmonious proportions:

  - **Card aspect ratio**: width/height ≈ φ (cards are golden rectangles)
  - **Outer margin to gap ratio**: outer padding = gap × φ (breathing room)
  - **Internal card padding**: top/bottom = side × φ (vertical emphasis)

  The grid adapts to the available terminal/viewport size. Columns are
  computed from the viewport width and a minimum card width. Cards fill
  the available space evenly, with fractional space distributed to margins.

  ## Rectangle format

  All rectangles are `{row, col, width, height}` tuples matching
  `MingaEditor.Layout.rect()`.
  """

  alias MingaEditor.Shell.Board.State

  # ── Golden ratio constants ─────────────────────────────────────────────

  # φ (phi), the golden ratio
  @phi 1.618

  # Minimum card dimensions in cells
  @min_card_width 30
  @min_card_height 9

  # Base gap between cards (in cells)
  @base_gap 2

  # ── Types ──────────────────────────────────────────────────────────────

  @typedoc "A screen rectangle: {row, col, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc "Computed layout for the Board grid."
  @type t :: %{
          card_rects: %{pos_integer() => rect()},
          grid_cols: pos_integer(),
          grid_rows: pos_integer(),
          header_rect: rect(),
          content_area: rect()
        }

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Computes the card grid layout for the given board state and viewport.

  Returns a map of card ID to rect, plus metadata about the grid
  dimensions. Cards are laid out in creation order (sorted by ID),
  left-to-right, top-to-bottom.
  """
  @spec compute(State.t(), pos_integer(), pos_integer()) :: t()
  def compute(%State{} = state, viewport_cols, viewport_rows)
      when viewport_cols > 0 and viewport_rows > 0 do
    cards = State.sorted_cards(state)

    # Reserve 1 row at top for header, 1 at bottom for status
    header_rect = {0, 0, viewport_cols, 1}
    content_top = 1
    content_height = max(viewport_rows - 2, 1)
    content_area = {content_top, 0, viewport_cols, content_height}

    if cards == [] do
      %{
        card_rects: %{},
        grid_cols: 1,
        grid_rows: 0,
        header_rect: header_rect,
        content_area: content_area
      }
    else
      compute_grid(cards, viewport_cols, content_top, content_height, header_rect, content_area)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec compute_grid(
          [MingaEditor.Shell.Board.Card.t()],
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          rect(),
          rect()
        ) :: t()
  defp compute_grid(cards, viewport_cols, content_top, content_height, header_rect, content_area) do
    # Compute gap and outer margin using golden ratio
    # Outer margin = gap × φ (more breathing room at edges)
    gap = @base_gap
    outer_margin = max(round(gap * @phi), gap + 1)

    # Compute number of columns that fit
    usable_width = viewport_cols - outer_margin * 2 + gap
    cols = max(div(usable_width, @min_card_width + gap), 1)

    # Actual card width: distribute available space evenly
    card_width = max(div(usable_width - gap * (cols - 1), cols), @min_card_width)

    # Card height from golden ratio: width / φ
    card_height_raw = round(card_width / @phi)
    card_height = max(card_height_raw, @min_card_height)

    # Rows needed
    card_count = length(cards)
    rows = max(ceil_div(card_count, cols), 1)

    # Vertical gap follows the same golden rhythm
    v_gap = max(round(gap / @phi), 1)

    # Recenter horizontally: actual grid width vs viewport
    grid_width = card_width * cols + gap * (cols - 1)
    left_offset = max(div(viewport_cols - grid_width, 2), outer_margin)

    # Vertical margin uses golden ratio of the gap
    v_outer_margin = max(round(v_gap * @phi), v_gap + 1)

    # Compute each card's rectangle
    card_rects =
      cards
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {card, idx}, acc ->
        grid_col = rem(idx, cols)
        grid_row = div(idx, cols)

        col = left_offset + grid_col * (card_width + gap)
        row = content_top + v_outer_margin + grid_row * (card_height + v_gap)

        # Clamp to content area bounds
        clamped_width = min(card_width, max(viewport_cols - col, 1))

        clamped_height =
          min(card_height, max(content_top + content_height - row, 1))

        if row < content_top + content_height and col < viewport_cols do
          Map.put(acc, card.id, {row, col, clamped_width, clamped_height})
        else
          # Card doesn't fit in viewport, still include with minimal rect
          Map.put(acc, card.id, {row, col, max(clamped_width, 1), max(clamped_height, 1)})
        end
      end)

    %{
      card_rects: card_rects,
      grid_cols: cols,
      grid_rows: rows,
      header_rect: header_rect,
      content_area: content_area
    }
  end

  # ── Card internal spacing ──────────────────────────────────────────────

  @doc """
  Computes internal padding for card content rendering.

  Returns `{pad_top, pad_right, pad_bottom, pad_left}` in cells.
  Vertical padding is side padding × φ for golden proportion.
  """
  @spec card_padding(pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def card_padding(card_width, card_height) do
    # Side padding: ~3% of width, at least 1 cell
    side = max(round(card_width * 0.03), 1)

    # Top/bottom: side × φ, but at least 1 and at most 1/4 of height
    vertical = min(max(round(side * @phi), 1), div(card_height, 4))

    {vertical, side, vertical, side}
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @spec ceil_div(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp ceil_div(a, b) when b > 0 do
    div(a + b - 1, b)
  end
end
