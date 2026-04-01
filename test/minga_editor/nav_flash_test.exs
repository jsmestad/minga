defmodule MingaEditor.NavFlashTest do
  use ExUnit.Case, async: true

  alias MingaEditor.NavFlash

  describe "start/2" do
    test "creates a flash struct at step 0 with send_after effect" do
      {flash, effects} = NavFlash.start(42)
      assert flash.line == 42
      assert flash.step == 0
      assert flash.max_steps == 3
      assert flash.timer == nil
      assert [{:send_after, :nav_flash_step, 100}] = effects
    end

    test "includes cancel_timer effect when existing timer provided" do
      fake_ref = make_ref()
      {flash, effects} = NavFlash.start(20, fake_ref)
      assert flash.line == 20
      assert flash.step == 0
      assert [{:cancel_timer, ^fake_ref}, {:send_after, :nav_flash_step, 100}] = effects
    end

    test "no cancel_timer effect when existing timer is nil" do
      {_flash, effects} = NavFlash.start(10, nil)
      assert [{:send_after, :nav_flash_step, 100}] = effects
    end
  end

  describe "advance/1" do
    test "increments step and returns {:continue, flash, effects}" do
      flash = %NavFlash{line: 10, step: 0, max_steps: 3, timer: nil}
      assert {:continue, advanced, effects} = NavFlash.advance(flash)
      assert advanced.step == 1
      assert advanced.line == 10
      assert [{:send_after, :nav_flash_step, 100}] = effects
    end

    test "returns :done when max_steps reached" do
      flash = %NavFlash{line: 10, step: 2, max_steps: 3, timer: nil}
      assert :done = NavFlash.advance(flash)
    end

    test "returns :done on last step" do
      flash = %NavFlash{line: 10, step: 1, max_steps: 2, timer: nil}
      assert :done = NavFlash.advance(flash)
    end
  end

  describe "cancel_effects/1" do
    test "returns empty list for nil" do
      assert NavFlash.cancel_effects(nil) == []
    end

    test "returns empty list when timer is nil" do
      flash = %NavFlash{line: 10, step: 0, max_steps: 3, timer: nil}
      assert NavFlash.cancel_effects(flash) == []
    end

    test "returns cancel_timer effect when timer exists" do
      ref = make_ref()
      flash = %NavFlash{line: 10, step: 0, max_steps: 3, timer: ref}
      assert [{:cancel_timer, ^ref}] = NavFlash.cancel_effects(flash)
    end
  end

  describe "color_for_step/3" do
    test "step 0 returns flash_bg" do
      flash = %NavFlash{line: 0, step: 0, max_steps: 3, timer: nil}
      assert NavFlash.color_for_step(flash, 0x3E4451, 0x2C323C) == 0x3E4451
    end

    test "final step returns target_bg" do
      flash = %NavFlash{line: 0, step: 2, max_steps: 3, timer: nil}
      assert NavFlash.color_for_step(flash, 0x3E4451, 0x2C323C) == 0x2C323C
    end

    test "middle step returns interpolated color" do
      flash = %NavFlash{line: 0, step: 1, max_steps: 3, timer: nil}
      color = NavFlash.color_for_step(flash, 0x3E4451, 0x2C323C)
      assert color != 0x3E4451
      assert color != 0x2C323C
    end

    test "single step flash returns flash_bg" do
      flash = %NavFlash{line: 0, step: 0, max_steps: 1, timer: nil}
      assert NavFlash.color_for_step(flash, 0xFF0000, 0x000000) == 0xFF0000
    end

    test "interpolates RGB channels independently" do
      flash = %NavFlash{line: 0, step: 1, max_steps: 3, timer: nil}
      # From pure red to pure blue: midpoint should have R=~128, G=0, B=~128
      color = NavFlash.color_for_step(flash, 0xFF0000, 0x0000FF)
      r = Bitwise.bsr(color, 16) |> Bitwise.band(0xFF)
      g = Bitwise.bsr(color, 8) |> Bitwise.band(0xFF)
      b = Bitwise.band(color, 0xFF)
      assert r in 127..128
      assert g == 0
      assert b in 127..128
    end
  end
end
