defmodule MingaEditor.Shell.Traditional.NavFlashTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.NavFlash

  test "replacement advances generation and resets animation state" do
    first = NavFlash.replace(%NavFlash{}, 42)
    timer = make_ref()
    first = NavFlash.record_timer(first, first.generation, timer)
    second = NavFlash.replace(first, 9)

    assert first.generation == 1
    assert first.timer == timer
    assert %NavFlash{generation: 2, line: 9, step: 0, timer: nil} = second
  end

  test "timer handles record only for the matching active generation" do
    flash = NavFlash.replace(%NavFlash{}, 10)
    timer = make_ref()
    assert NavFlash.record_timer(flash, flash.generation - 1, timer) == flash
    assert %NavFlash{timer: ^timer} = NavFlash.record_timer(flash, flash.generation, timer)
  end

  test "stale timer generations cannot advance a replacement" do
    first = NavFlash.replace(%NavFlash{}, 10)
    replacement = NavFlash.replace(first, 20)

    assert {:stale, ^replacement} = NavFlash.advance(replacement, first.generation)

    assert {:continue, %NavFlash{line: 20, step: 1}} =
             NavFlash.advance(replacement, replacement.generation)
  end

  test "matching generation completes and cancellation retains generation" do
    flash = %NavFlash{generation: 3, line: 10, step: 2, max_steps: 3}
    assert {:done, done} = NavFlash.advance(flash, 3)
    refute NavFlash.active?(done)
    assert done.generation == 3

    active = NavFlash.replace(done, 11)
    canceled = NavFlash.cancel(active)
    refute NavFlash.active?(canceled)
    assert canceled.generation == active.generation
  end

  test "color interpolation reaches both endpoints" do
    assert NavFlash.color_for_step(%NavFlash{step: 0, max_steps: 3}, 0xFF0000, 0x0000FF) ==
             0xFF0000

    assert NavFlash.color_for_step(%NavFlash{step: 2, max_steps: 3}, 0xFF0000, 0x0000FF) ==
             0x0000FF
  end
end
