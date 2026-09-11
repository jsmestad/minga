defmodule Minga.Core.ColorTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Color

  test "interpolates each RGB channel" do
    assert Color.interpolate(0x000000, 0xFFFFFF, 0.5) == 0x808080
    assert Color.interpolate(0x102030, 0x506070, 0.25) == 0x203040
  end

  test "clamps fractions to the endpoint colors" do
    assert Color.interpolate(0x102030, 0xA0B0C0, -0.1) == 0x102030
    assert Color.interpolate(0x102030, 0xA0B0C0, 0.0) == 0x102030
    assert Color.interpolate(0x102030, 0xA0B0C0, 1.0) == 0xA0B0C0
    assert Color.interpolate(0x102030, 0xA0B0C0, 1.1) == 0xA0B0C0
  end
end
