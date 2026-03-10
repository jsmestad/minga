defmodule Minga.Scroll do
  @moduledoc """
  Generic scroll state for any content region that can be scrolled.

  Encapsulates a three-part model:

    * `offset` — concrete line count from the top of the content.
      Always a real number, never a sentinel.
    * `pinned` — boolean flag meaning "follow the bottom."
      When true, the renderer ignores `offset` and computes the
      bottom position from the actual content dimensions.
    * `metrics` — cached `{total_lines, visible_height}` from the
      most recent render pass. Updated by the render pipeline after
      every frame so that `scroll_up/2` and `scroll_down/2` can
      resolve a pinned position into a concrete offset without the
      caller passing dimensions.

  ## Usage

  Embed a `%Scroll{}` in any struct that needs scrollable content:

      defstruct scroll: Scroll.new()

  The render pipeline must call `update_metrics/3` after computing
  content dimensions. Scroll functions are then self-sufficient:
  every caller just calls `scroll_up/2` or `scroll_down/2` without
  passing content dimensions or calling a materialization step.
  """

  @typedoc """
  Cached metrics from the most recent render pass.

  Updated by the render pipeline after each frame. Between frames no
  scroll commands execute, so the cache is always fresh when it matters.
  """
  @type metrics :: %{total_lines: non_neg_integer(), visible_height: pos_integer()}

  @typedoc "Scroll state for a content region."
  @type t :: %__MODULE__{
          offset: non_neg_integer(),
          pinned: boolean(),
          metrics: metrics()
        }

  @enforce_keys []
  defstruct offset: 0,
            pinned: true,
            metrics: %{total_lines: 0, visible_height: 1}

  @doc "Creates a new scroll state, pinned to bottom."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Creates a new scroll state starting at a specific offset, unpinned."
  @spec new(non_neg_integer()) :: t()
  def new(offset) when is_integer(offset) and offset >= 0 do
    %__MODULE__{offset: offset, pinned: false}
  end

  # ── Scrolling ──────────────────────────────────────────────────────────────

  @doc """
  Scrolls up by the given number of lines. Unpins from bottom.

  When transitioning from pinned, uses cached metrics to compute the
  concrete bottom offset before subtracting.
  """
  @spec scroll_up(t(), non_neg_integer()) :: t()
  def scroll_up(%__MODULE__{pinned: true, metrics: metrics} = scroll, amount) do
    bottom = max(metrics.total_lines - metrics.visible_height, 0)
    %{scroll | offset: max(bottom - amount, 0), pinned: false}
  end

  def scroll_up(%__MODULE__{} = scroll, amount) do
    %{scroll | offset: max(scroll.offset - amount, 0), pinned: false}
  end

  @doc """
  Scrolls down by the given number of lines. Unpins from bottom.

  When transitioning from pinned, uses cached metrics to compute the
  concrete bottom offset before adding. The renderer clamps overshoot,
  so unbounded addition is safe.
  """
  @spec scroll_down(t(), non_neg_integer()) :: t()
  def scroll_down(%__MODULE__{pinned: true, metrics: metrics} = scroll, amount) do
    bottom = max(metrics.total_lines - metrics.visible_height, 0)
    %{scroll | offset: bottom + amount, pinned: false}
  end

  def scroll_down(%__MODULE__{} = scroll, amount) do
    %{scroll | offset: scroll.offset + amount, pinned: false}
  end

  @doc """
  Pins to the bottom. The renderer resolves this to a concrete line
  number at render time using the actual content dimensions.
  """
  @spec pin_to_bottom(t()) :: t()
  def pin_to_bottom(%__MODULE__{} = scroll) do
    %{scroll | pinned: true}
  end

  @doc "Scrolls to the top. Unpins from bottom."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{} = scroll) do
    %{scroll | offset: 0, pinned: false}
  end

  @doc """
  Sets the offset to an absolute value. Unpins from bottom.

  Used by search navigation, code block jumping, and other features
  that need to position the viewport at a specific line.
  """
  @spec set_offset(t(), non_neg_integer()) :: t()
  def set_offset(%__MODULE__{} = scroll, offset) when is_integer(offset) and offset >= 0 do
    %{scroll | offset: offset, pinned: false}
  end

  # ── Render pipeline integration ───────────────────────────────────────────

  @doc """
  Updates the cached metrics from the most recent render pass.

  Called by the render pipeline after computing content dimensions.
  Must be called every frame so that scroll_up/scroll_down have
  accurate dimensions when transitioning from pinned to manual.
  """
  @spec update_metrics(t(), non_neg_integer(), pos_integer()) :: t()
  def update_metrics(%__MODULE__{} = scroll, total_lines, visible_height)
      when is_integer(total_lines) and total_lines >= 0 and
             is_integer(visible_height) and visible_height >= 1 do
    %{scroll | metrics: %{total_lines: total_lines, visible_height: visible_height}}
  end

  @doc """
  Resolves the effective scroll offset for rendering.

  When pinned, computes `max(total_lines - visible_height, 0)`.
  When unpinned, clamps `offset` to the valid range.

  Renderers call this instead of reading `offset` directly.
  """
  @spec resolve(t(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  def resolve(%__MODULE__{pinned: true}, total_lines, visible_height) do
    max(total_lines - visible_height, 0)
  end

  def resolve(%__MODULE__{offset: offset}, total_lines, visible_height) do
    min(offset, max(total_lines - visible_height, 0))
  end
end
