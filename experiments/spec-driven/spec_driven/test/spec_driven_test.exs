defmodule SpecDrivenTest do
  use ExUnit.Case
  doctest SpecDriven

  test "greets the world" do
    assert SpecDriven.hello() == :world
  end
end
