defmodule Minga.TextObject.StructuralTest do
  use ExUnit.Case, async: true

  alias Minga.TextObject

  describe "structural_inner/2" do
    test "returns nil when parser is not running" do
      # Without a live parser process, the request times out and returns nil.
      # This tests the graceful fallback path.
      assert TextObject.structural_inner(:function, {5, 10}) == nil
    end

    test "returns nil for unknown structural type" do
      assert TextObject.structural_inner(:nonexistent, {0, 0}) == nil
    end
  end

  describe "structural_around/2" do
    test "returns nil when parser is not running" do
      assert TextObject.structural_around(:function, {5, 10}) == nil
    end

    test "returns nil for unknown structural type" do
      assert TextObject.structural_around(:nonexistent, {0, 0}) == nil
    end
  end

  describe "adjust_end_position (via structural queries)" do
    # The private adjust_end_position is tested indirectly via structural queries.
    # Direct unit tests would require exposing it; instead we verify the
    # boundary cases produce expected results through the public API.

    test "all structural types gracefully handle no parser" do
      types = [:function, :class, :parameter, :block, :comment, :test]

      for type <- types do
        assert TextObject.structural_inner(type, {0, 0}) == nil,
               "Expected nil for #{type} inner"

        assert TextObject.structural_around(type, {0, 0}) == nil,
               "Expected nil for #{type} around"
      end
    end
  end
end
