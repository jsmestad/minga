defmodule MingaEditor.UI.Highlight.SpanTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Highlight.Span

  describe "new/5" do
    test "creates a span with all fields" do
      span = Span.new(0, 10, 3, 5, 2)
      assert span.start_byte == 0
      assert span.end_byte == 10
      assert span.capture_id == 3
      assert span.pattern_index == 5
      assert span.layer == 2
    end

    test "defaults pattern_index and layer to 0" do
      span = Span.new(0, 10, 3)
      assert span.pattern_index == 0
      assert span.layer == 0
    end
  end

  describe "@enforce_keys" do
    test "requires start_byte, end_byte, and capture_id" do
      assert_raise ArgumentError, fn ->
        struct!(Span, %{start_byte: 0, end_byte: 10})
      end
    end
  end
end
