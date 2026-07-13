defmodule MingaEditor.Shell.Traditional.YankFlashTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.YankFlash

  test "replacement advances generation and preserves range identity" do
    first = YankFlash.replace(%YankFlash{}, self(), {1, 2}, {3, 4}, :charwise)
    timer = make_ref()
    first = YankFlash.record_timer(first, first.generation, timer)
    second = YankFlash.replace(first, self(), {5, 0}, {7, 0}, :linewise)

    assert first.timer == timer

    assert %YankFlash{
             generation: 2,
             buf: buf,
             start_pos: {5, 0},
             end_pos: {7, 0},
             range_type: :linewise,
             step: 0,
             timer: nil
           } = second

    assert buf == self()
  end

  test "stale timer generations cannot advance a replacement" do
    first = YankFlash.replace(%YankFlash{}, self(), {0, 0}, {0, 3}, :charwise)
    replacement = YankFlash.replace(first, self(), {1, 0}, {1, 4}, :charwise)

    assert {:stale, ^replacement} = YankFlash.advance(replacement, first.generation)

    assert {:continue, %YankFlash{start_pos: {1, 0}, step: 1}} =
             YankFlash.advance(replacement, replacement.generation)
  end

  test "matching generation completes and cancellation retains generation" do
    flash = %YankFlash{generation: 4, buf: self(), step: 3, max_steps: 4}
    assert {:done, done} = YankFlash.advance(flash, 4)
    refute YankFlash.active?(done)
    assert done.generation == 4

    active = YankFlash.replace(done, self(), {0, 0}, {0, 1}, :charwise)
    canceled = YankFlash.cancel(active)
    refute YankFlash.active?(canceled)
    assert canceled.generation == active.generation
  end

  test "charwise bounds pass through and color reaches endpoints" do
    assert YankFlash.highlight_bounds({1, 2}, {3, 4}, :charwise, 0) ==
             {{1, 2}, {3, 4}}

    assert YankFlash.highlight_bounds({1, 2}, {3, 4}, :linewise, 12) ==
             {{1, 0}, {3, 12}}

    assert YankFlash.color_for_step(%YankFlash{step: 0, max_steps: 4}, 0xFF0000, 0) ==
             0xFF0000

    assert YankFlash.color_for_step(%YankFlash{step: 3, max_steps: 4}, 0xFF0000, 0) == 0
    assert YankFlash.flash_group() == :yank_flash
  end
end
