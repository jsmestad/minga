defmodule MingaEditor.YankFlashTest do
  use ExUnit.Case, async: true

  alias MingaEditor.YankFlash

  describe "start/5" do
    test "creates a flash struct at step 0 with send_after effect" do
      buf = self()
      {flash, effects} = YankFlash.start(buf, {0, 0}, {0, 10}, :charwise)

      assert %YankFlash{
               buf: ^buf,
               start_pos: {0, 0},
               end_pos: {0, 10},
               range_type: :charwise,
               step: 0,
               max_steps: 4,
               timer: nil
             } = flash

      assert [{:send_after, :yank_flash_step, 60}] = effects
    end

    test "includes cancel_timer effect when existing timer provided" do
      ref = make_ref()
      {_flash, effects} = YankFlash.start(self(), {1, 0}, {3, 5}, :linewise, ref)

      assert [{:cancel_timer, ^ref}, {:send_after, :yank_flash_step, 60}] = effects
    end

    test "no cancel_timer effect when existing timer is nil" do
      {_flash, effects} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise, nil)

      assert [{:send_after, :yank_flash_step, 60}] = effects
    end

    test "preserves buf, start_pos, end_pos, range_type" do
      buf = self()
      {flash, _effects} = YankFlash.start(buf, {5, 3}, {10, 7}, :linewise)

      assert flash.buf == buf
      assert flash.start_pos == {5, 3}
      assert flash.end_pos == {10, 7}
      assert flash.range_type == :linewise
    end
  end

  describe "advance/1" do
    test "increments step and returns {:continue, flash, effects}" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)

      assert {:continue, updated, effects} = YankFlash.advance(flash)
      assert updated.step == 1
      assert [{:send_after, :yank_flash_step, 60}] = effects
    end

    test "continues through multiple steps" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)

      {:continue, flash, _} = YankFlash.advance(flash)
      assert flash.step == 1

      {:continue, flash, _} = YankFlash.advance(flash)
      assert flash.step == 2
    end

    test "returns :done when max_steps reached" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)

      {:continue, flash, _} = YankFlash.advance(flash)
      {:continue, flash, _} = YankFlash.advance(flash)
      {:continue, flash, _} = YankFlash.advance(flash)

      assert :done = YankFlash.advance(flash)
    end

    test "clears timer on advance" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)
      flash = %{flash | timer: make_ref()}

      {:continue, updated, _} = YankFlash.advance(flash)
      assert updated.timer == nil
    end
  end

  describe "cancel_effects/1" do
    test "returns empty list for nil" do
      assert [] = YankFlash.cancel_effects(nil)
    end

    test "returns empty list when timer is nil" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)
      assert [] = YankFlash.cancel_effects(flash)
    end

    test "returns cancel_timer effect when timer exists" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)
      ref = make_ref()
      flash = %{flash | timer: ref}

      assert [{:cancel_timer, ^ref}] = YankFlash.cancel_effects(flash)
    end
  end

  describe "color_for_step/3" do
    test "step 0 returns flash_bg" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)

      assert YankFlash.color_for_step(flash, 0xFF0000, 0x000000) == 0xFF0000
    end

    test "final step returns target_bg" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)
      flash = %{flash | step: 3}

      assert YankFlash.color_for_step(flash, 0xFF0000, 0x000000) == 0x000000
    end

    test "middle step returns interpolated color" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)
      flash = %{flash | step: 1}

      color = YankFlash.color_for_step(flash, 0xFF0000, 0x000000)
      assert color != 0xFF0000
      assert color != 0x000000

      r = Bitwise.bsr(color, 16) |> Bitwise.band(0xFF)
      assert r > 0 and r < 255
    end

    test "interpolation is monotonic from flash_bg to target_bg" do
      {flash, _} = YankFlash.start(self(), {0, 0}, {0, 5}, :charwise)

      colors =
        for step <- 0..3 do
          YankFlash.color_for_step(%{flash | step: step}, 0xFF0000, 0x000000)
        end

      reds = Enum.map(colors, fn c -> Bitwise.bsr(c, 16) |> Bitwise.band(0xFF) end)
      assert reds == Enum.sort(reds, :desc)
    end
  end

  describe "flash_group/0" do
    test "returns :yank_flash" do
      assert YankFlash.flash_group() == :yank_flash
    end
  end
end
