defmodule Minga.Editor.State.Mouse do
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

  alias Minga.Editor.WindowTree

  # Double-click timing window (milliseconds)
  @double_click_ms 400
  # Maximum cell distance between clicks to count as multi-click
  @click_distance 2

  defstruct dragging: false,
            anchor: nil,
            resize_dragging: nil,
            last_press_time: nil,
            last_press_pos: nil,
            click_count: 0,
            drag_click_count: 1,
            hover_pos: nil,
            hover_timer: nil

  @type t :: %__MODULE__{
          dragging: boolean(),
          anchor: {non_neg_integer(), non_neg_integer()} | nil,
          resize_dragging: {WindowTree.direction() | :agent_separator, non_neg_integer()} | nil,
          last_press_time: integer() | nil,
          last_press_pos: {integer(), integer()} | nil,
          click_count: non_neg_integer(),
          drag_click_count: pos_integer(),
          hover_pos: {integer(), integer()} | nil,
          hover_timer: reference() | nil
        }

  @doc "Begins a content drag from the given buffer position."
  @spec start_drag(t(), {non_neg_integer(), non_neg_integer()}) :: t()
  def start_drag(%__MODULE__{} = mouse, anchor) do
    %{mouse | dragging: true, anchor: anchor, drag_click_count: max(mouse.click_count, 1)}
  end

  @doc "Ends an active drag, clearing the anchor."
  @spec stop_drag(t()) :: t()
  def stop_drag(%__MODULE__{} = mouse) do
    %{mouse | dragging: false, anchor: nil}
  end

  @doc "Begins a separator resize drag in the given direction at the given position."
  @spec start_resize(t(), WindowTree.direction() | :agent_separator, non_neg_integer()) :: t()
  def start_resize(%__MODULE__{} = mouse, direction, position) do
    %{mouse | resize_dragging: {direction, position}}
  end

  @doc "Updates the separator position during an active resize drag."
  @spec update_resize(t(), WindowTree.direction() | :agent_separator, non_neg_integer()) :: t()
  def update_resize(%__MODULE__{} = mouse, direction, new_position) do
    %{mouse | resize_dragging: {direction, new_position}}
  end

  @doc "Ends a separator resize drag."
  @spec stop_resize(t()) :: t()
  def stop_resize(%__MODULE__{} = mouse) do
    %{mouse | resize_dragging: nil}
  end

  @doc "Returns true if a separator resize drag is active."
  @spec resizing?(t()) :: boolean()
  def resizing?(%__MODULE__{resize_dragging: {_, _}}), do: true
  def resizing?(%__MODULE__{}), do: false

  # ── Multi-click detection ──────────────────────────────────────────────────

  @doc """
  Records a mouse press and computes the effective click count.

  If `native_click_count > 1`, uses that directly (GUI frontend).
  Otherwise, detects multi-clicks by timing and position (TUI fallback).

  Returns the updated mouse state with `click_count` set.
  """
  @spec record_press(t(), integer(), integer(), pos_integer()) :: t()
  def record_press(%__MODULE__{} = mouse, row, col, native_click_count) do
    now = System.monotonic_time(:millisecond)

    effective_count =
      if native_click_count > 1 do
        # GUI sends native click count; trust it
        min(native_click_count, 3)
      else
        # TUI: detect multi-click from timing
        compute_click_count(mouse, row, col, now)
      end

    %{mouse | last_press_time: now, last_press_pos: {row, col}, click_count: effective_count}
  end

  @spec compute_click_count(t(), integer(), integer(), integer()) :: pos_integer()
  defp compute_click_count(
         %{
           last_press_time: prev_time,
           last_press_pos: {prev_row, prev_col},
           click_count: prev_count
         },
         row,
         col,
         now
       )
       when is_integer(prev_time) do
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

  defp compute_click_count(_mouse, _row, _col, _now), do: 1

  @doc "Returns the double-click timing window in milliseconds (for testing)."
  @spec double_click_ms() :: pos_integer()
  def double_click_ms, do: @double_click_ms

  # ── Hover tracking ─────────────────────────────────────────────────────────

  @doc "Sets the hover position and starts a debounce timer."
  @spec set_hover(t(), integer(), integer(), keyword()) :: t()
  def set_hover(%__MODULE__{} = mouse, row, col, opts \\ []) do
    cancel_hover_timer(mouse)

    timer =
      if Keyword.get(opts, :backend) != :headless do
        Process.send_after(self(), :mouse_hover_timeout, 500)
      end

    %{mouse | hover_pos: {row, col}, hover_timer: timer}
  end

  @doc "Clears hover state and cancels any pending timer."
  @spec clear_hover(t()) :: t()
  def clear_hover(%__MODULE__{} = mouse) do
    cancel_hover_timer(mouse)
    %{mouse | hover_pos: nil, hover_timer: nil}
  end

  @spec cancel_hover_timer(t()) :: :ok
  defp cancel_hover_timer(%{hover_timer: nil}), do: :ok

  defp cancel_hover_timer(%{hover_timer: ref}) do
    Process.cancel_timer(ref)
    :ok
  end
end
