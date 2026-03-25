defmodule Minga.UI.Highlight.InjectionRangeTest do
  use ExUnit.Case, async: true

  alias Minga.UI.Highlight.InjectionRange

  describe "new/3" do
    test "creates an injection range" do
      range = InjectionRange.new(100, 200, "javascript")
      assert range.start_byte == 100
      assert range.end_byte == 200
      assert range.language == "javascript"
    end
  end

  describe "@enforce_keys" do
    test "requires all three fields" do
      assert_raise ArgumentError, fn ->
        struct!(InjectionRange, %{start_byte: 0, end_byte: 10})
      end
    end
  end
end
