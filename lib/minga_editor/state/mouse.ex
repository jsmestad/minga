defmodule MingaEditor.State.Mouse do
  @moduledoc """
  Mouse interaction state: drag tracking, anchor position, separator resize,
  multi-click detection, and hover tracking.

  ## Multi-click detection

  The TUI always sends `click_count: 1` because libvaxis doesn't track
  multi-clicks. The BEAM detects double/triple-clicks by comparing press
  timestamps and positions. GUI frontends send the native click count
  directly, so BEAM detection is skipped when `click_count > 1`.

  Two presses within `@double_click_ms` milliseconds at the same position
  (within `@click_distance` cells) increment the click count. The count
  resets on motion, timeout, or a click at a different position.
  """

  alias MingaEditor.WindowTree

  # Double-click timing window (milliseconds)
  @double_click_ms 400
  # Maximum cell distance between clicks to count as multi-click
  @click_distance 2
  # Hover debounce before requesting an LSP hover. Matches the VSCode default
  # (`editor.hover.delay`) so a hovered symbol resolves quickly but transient
  # pointer motion does not thrash the LSP.
  @hover_delay_ms 300

  defstruct drag: :idle,
            resize: :idle,
            clicks: :idle,
            hover: :idle

  @type drag ::
          :idle
          | {:active,
             %{
               anchor: {non_neg_integer(), non_neg_integer()},
               origin_window: MingaEditor.Window.id() | nil,
               click_count: pos_integer()
             }}
  @type resize ::
          :idle | {:active, {WindowTree.direction() | :agent_separator, non_neg_integer()}}
  @type clicks ::
          :idle
          | {:pressed,
             %{
               time: integer(),
               pos: {integer(), integer()},
               count: pos_integer()
             }}
  @type hover :: :idle | {:active, {integer(), integer()}, reference() | nil}

  @type t :: %__MODULE__{
          drag: drag(),
          resize: resize(),
          clicks: clicks(),
          hover: hover()
        }

  @doc "Begins a content drag from the given buffer position."
  @spec start_drag(t(), {non_neg_integer(), non_neg_integer()}) :: t()
  def start_drag(%__MODULE__{} = mouse, anchor) do
    start_drag(mouse, anchor, nil)
  end

  @doc "Begins a content drag from the given buffer position and originating window."
  @spec start_drag(t(), {non_neg_integer(), non_neg_integer()}, MingaEditor.Window.id() | nil) ::
          t()
  def start_drag(%__MODULE__{} = mouse, anchor, origin_window) do
    %{
      mouse
      | drag:
          {:active,
           %{
             anchor: anchor,
             origin_window: origin_window,
             click_count: max(click_count(mouse), 1)
           }}
    }
  end

  @spec stop_drag(t()) :: t()
  def stop_drag(%__MODULE__{} = mouse), do: %{mouse | drag: :idle}

  @spec dragging?(t()) :: boolean()
  def dragging?(%__MODULE__{drag: {:active, _}}), do: true
  def dragging?(%__MODULE__{drag: :idle}), do: false

  @spec active_drag(t()) ::
          {:active, {non_neg_integer(), non_neg_integer()}, MingaEditor.Window.id() | nil,
           pos_integer()}
          | :idle
  def active_drag(%__MODULE__{
        drag: {:active, %{anchor: anchor, origin_window: origin_window, click_count: click_count}}
      }) do
    {:active, anchor, origin_window, click_count}
  end

  def active_drag(%__MODULE__{drag: :idle}), do: :idle

  @spec start_resize(t(), WindowTree.direction() | :agent_separator, non_neg_integer()) :: t()
  def start_resize(%__MODULE__{} = mouse, direction, position) do
    %{mouse | resize: {:active, {direction, position}}}
  end

  @spec update_resize(t(), WindowTree.direction() | :agent_separator, non_neg_integer()) :: t()
  def update_resize(%__MODULE__{resize: {:active, _}} = mouse, direction, new_position) do
    %{mouse | resize: {:active, {direction, new_position}}}
  end

  def update_resize(%__MODULE__{resize: :idle} = mouse, _direction, _new_position), do: mouse

  @spec stop_resize(t()) :: t()
  def stop_resize(%__MODULE__{} = mouse), do: %{mouse | resize: :idle}

  @spec resizing?(t()) :: boolean()
  def resizing?(%__MODULE__{resize: {:active, _}}), do: true
  def resizing?(%__MODULE__{resize: :idle}), do: false

  # ── Multi-click detection ──────────────────────────────────────────────────

  @doc """
  Records a mouse press and computes the effective click count.

  If `native_click_count > 1`, uses that directly (GUI frontend).
  Otherwise, detects multi-clicks by timing and position (TUI fallback).

  Returns the updated mouse state with the effective click count set.
  """
  @spec record_press(t(), integer(), integer(), pos_integer()) :: t()
  def record_press(%__MODULE__{} = mouse, row, col, native_click_count),
    do: record_press_at(mouse, row, col, native_click_count, 0)

  @spec record_press_at(t(), integer(), integer(), pos_integer(), integer()) :: t()
  def record_press_at(%__MODULE__{} = mouse, row, col, native_click_count, now)
      when is_integer(now) do
    effective_count =
      if native_click_count > 1 do
        # GUI sends native click count; trust it
        min(native_click_count, 3)
      else
        # TUI: detect multi-click from timing
        compute_click_count(mouse, row, col, now)
      end

    %{mouse | clicks: {:pressed, %{time: now, pos: {row, col}, count: effective_count}}}
  end

  @spec click_count(t()) :: non_neg_integer()
  def click_count(%__MODULE__{clicks: {:pressed, %{count: count}}}), do: count
  def click_count(%__MODULE__{clicks: :idle}), do: 0

  @spec compute_click_count(t(), integer(), integer(), integer()) :: pos_integer()
  defp compute_click_count(
         %__MODULE__{
           clicks: {:pressed, %{time: prev_time, pos: {prev_row, prev_col}, count: prev_count}}
         },
         row,
         col,
         now
       ) do
    time_ok = now - prev_time <= @double_click_ms
    pos_ok = abs(row - prev_row) <= @click_distance and abs(col - prev_col) <= @click_distance

    if time_ok and pos_ok do
      # Cycle: 1 → 2 → 3 → 1
      case prev_count do
        3 -> 1
        n -> n + 1
      end
    else
      1
    end
  end

  defp compute_click_count(%__MODULE__{clicks: :idle}, _row, _col, _now), do: 1

  @spec double_click_ms() :: pos_integer()
  def double_click_ms, do: @double_click_ms

  @spec hover_delay_ms() :: pos_integer()
  def hover_delay_ms, do: @hover_delay_ms

  # ── Hover tracking ─────────────────────────────────────────────────────────

  @spec set_hover(t(), integer(), integer(), keyword()) :: t()
  def set_hover(%__MODULE__{} = mouse, row, col, _opts \\ []) do
    {mouse, _timer, _schedule?} = prepare_hover(mouse, row, col, backend: :headless)

    mouse
  end

  @spec prepare_hover(t(), integer(), integer(), keyword()) :: {t(), reference() | nil, boolean()}
  def prepare_hover(%__MODULE__{} = mouse, row, col, opts \\ []) do
    {
      %{mouse | hover: {:active, {row, col}, nil}},
      hover_timer(mouse),
      Keyword.get(opts, :backend) != :headless
    }
  end

  @spec accept_hover_timer(t(), reference()) :: t()
  def accept_hover_timer(%__MODULE__{hover: {:active, pos, nil}} = mouse, timer)
      when is_reference(timer),
      do: %{mouse | hover: {:active, pos, timer}}

  def accept_hover_timer(%__MODULE__{} = mouse, timer) when is_reference(timer), do: mouse

  @spec clear_hover(t()) :: t()
  def clear_hover(%__MODULE__{} = mouse), do: %{mouse | hover: :idle}

  @spec prepare_clear_hover(t()) :: {t(), reference() | nil}
  def prepare_clear_hover(%__MODULE__{} = mouse),
    do: {%{mouse | hover: :idle}, hover_timer(mouse)}

  @spec hover_position(t()) :: {integer(), integer()} | nil
  def hover_position(%__MODULE__{hover: {:active, pos, _timer}}), do: pos
  def hover_position(%__MODULE__{hover: :idle}), do: nil

  @spec hover_timer(t()) :: reference() | nil
  defp hover_timer(%__MODULE__{hover: {:active, _pos, timer}}), do: timer
  defp hover_timer(%__MODULE__{hover: :idle}), do: nil
end
