defmodule Minga.Buffer.SpanTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Span

  describe "between/2" do
    test "builds a half-open span from ordered points" do
      assert Span.between(1, 4) == %Span{start: 1, stop: 4}
    end

    test "normalises reversed points" do
      assert Span.between(4, 1) == %Span{start: 1, stop: 4}
    end
  end

  describe "characterwise/3" do
    test "includes the character at the final point" do
      text = "abcdef"
      span = Span.characterwise(text, 1, 3)

      assert span == %Span{start: 1, stop: 4}
      assert Span.slice(text, span) == "bcd"
    end

    test "normalises reversed points while keeping the final character inclusive" do
      text = "abcdef"
      span = Span.characterwise(text, 3, 1)

      assert span == %Span{start: 1, stop: 4}
      assert Span.slice(text, span) == "bcd"
    end

    test "includes a full multi-byte character" do
      text = "a🥨b"
      span = Span.characterwise(text, 1, 1)

      assert Span.slice(text, span) == "🥨"
    end

    test "returns an empty span at the end of the text" do
      text = "ab"
      span = Span.characterwise(text, 2, 2)

      assert span == %Span{start: 2, stop: 2}
      assert Span.slice(text, span) == ""
    end
  end

  describe "slice/2" do
    test "returns the text covered by a half-open span" do
      assert Span.slice("abcdef", %Span{start: 2, stop: 5}) == "cde"
    end
  end

  describe "delete/2" do
    test "removes the text covered by a half-open span" do
      assert Span.delete("abcdef", %Span{start: 2, stop: 5}) == "abf"
    end

    test "can delete the whole text" do
      assert Span.delete("abc", %Span{start: 0, stop: 3}) == ""
    end
  end
end
