defmodule MingaEditor.State.ResourcePressureTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.ResourcePressure

  describe "render_delay_ms/1" do
    test "normal operation preserves caller-selected render cadence" do
      pressure = ResourcePressure.new()

      assert ResourcePressure.render_delay_ms(pressure) == 0
    end

    test "low power mode caps scheduled rendering at 30fps" do
      pressure = ResourcePressure.update(ResourcePressure.new(), true, :nominal)

      assert ResourcePressure.render_delay_ms(pressure) == 33
    end

    test "low power mode still throttles unknown thermal pressure" do
      pressure = ResourcePressure.update(ResourcePressure.new(), true, {:unknown, 255})

      assert ResourcePressure.render_delay_ms(pressure) == 33
    end

    test "low power mode does not override fair thermal pressure" do
      pressure = ResourcePressure.update(ResourcePressure.new(), true, :fair)

      assert ResourcePressure.render_delay_ms(pressure) == 22
    end

    test "thermal pressure progressively increases render debounce" do
      fair = ResourcePressure.update(ResourcePressure.new(), false, :fair)
      serious = ResourcePressure.update(ResourcePressure.new(), false, :serious)
      critical = ResourcePressure.update(ResourcePressure.new(), false, :critical)

      assert ResourcePressure.render_delay_ms(fair) == 22
      assert ResourcePressure.render_delay_ms(serious) == 33
      assert ResourcePressure.render_delay_ms(critical) == 100
    end
  end
end
