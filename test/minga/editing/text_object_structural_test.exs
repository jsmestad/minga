defmodule Minga.Editing.TextObject.StructuralTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.TextObject

  # All tests use buffer_id 0 since no real parser is running.
  @buffer_id 0

  describe "structural_inner/3" do
    test "returns nil when parser is not running" do
      # Without a live parser process, the request times out and returns nil.
      # This tests the graceful fallback path.
      assert TextObject.structural_inner(:function, {5, 10}, @buffer_id) == nil
    end

    test "returns nil for unknown structural type" do
      assert TextObject.structural_inner(:nonexistent, {0, 0}, @buffer_id) == nil
    end
  end

  describe "structural_around/3" do
    test "returns nil when parser is not running" do
      assert TextObject.structural_around(:function, {5, 10}, @buffer_id) == nil
    end

    test "returns nil for unknown structural type" do
      assert TextObject.structural_around(:nonexistent, {0, 0}, @buffer_id) == nil
    end
  end

  describe "adjust_end_position (via structural queries)" do
    test "all structural types gracefully handle no parser" do
      types = [:function, :class, :parameter, :block, :comment, :test]

      for type <- types do
        assert TextObject.structural_inner(type, {0, 0}, @buffer_id) == nil,
               "Expected nil for #{type} inner"

        assert TextObject.structural_around(type, {0, 0}, @buffer_id) == nil,
               "Expected nil for #{type} around"
      end
    end
  end
end
