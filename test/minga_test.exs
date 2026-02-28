defmodule MingaTest do
  use ExUnit.Case, async: true

  test "version returns a string" do
    assert is_binary(Minga.version())
    assert Minga.version() == "0.1.0"
  end
end
