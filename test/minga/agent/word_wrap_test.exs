defmodule Minga.Agent.WordWrapTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.WordWrap

  describe "wrap_segments/3" do
    test "returns single line when text fits within width" do
      segments = [{"Hello world", [fg: :white]}]
      assert WordWrap.wrap_segments(segments, 20) == [segments]
    end

    test "wraps at word boundary" do
      segments = [{"Hello world, this is a test", [fg: :white]}]
      result = WordWrap.wrap_segments(segments, 15)

      # Each line should be a list of segments
      assert length(result) > 1

      # Reconstruct text from all lines
      full_text =
        result
        |> Enum.map_join(" ", fn line ->
          Enum.map_join(line, "", fn {text, _} -> text end)
        end)
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      assert full_text == "Hello world, this is a test"
    end

    test "continuation lines are indented" do
      segments = [{"Hello world, this is a long sentence", [fg: :white]}]
      result = WordWrap.wrap_segments(segments, 15)

      # First line should not start with indent
      [{first_text, _} | _] = hd(result)
      refute String.starts_with?(first_text, "  ")

      # Second line should start with indent
      [{indent_text, _} | _] = Enum.at(result, 1)
      assert indent_text == "  "
    end

    test "preserves style across word boundaries" do
      segments = [
        {"bold", [bold: true]},
        {" text here", [fg: :white]}
      ]

      result = WordWrap.wrap_segments(segments, 8)

      # Should have multiple lines
      assert length(result) > 1

      # First line should have the bold style
      first_line = hd(result)
      bold_seg = Enum.find(first_line, fn {_, opts} -> Keyword.get(opts, :bold) end)
      assert bold_seg != nil
    end

    test "handles empty segments" do
      assert WordWrap.wrap_segments([], 20) == [[]]
    end

    test "breaks long words that exceed width" do
      segments = [{"superlongwordthatexceedswidth", [fg: :white]}]
      result = WordWrap.wrap_segments(segments, 10)

      # Should split the word across lines
      assert length(result) > 1

      # Each line's content (minus indent) should be at most width chars
      Enum.each(result, fn line ->
        text_len =
          line
          |> Enum.map(fn {text, _} -> String.length(text) end)
          |> Enum.sum()

        assert text_len <= 10
      end)
    end

    test "custom indent string" do
      segments = [{"Hello world, this is a test", [fg: :white]}]
      result = WordWrap.wrap_segments(segments, 15, ">>> ")

      # Second line should use custom indent
      if length(result) > 1 do
        [{indent_text, _} | _] = Enum.at(result, 1)
        assert indent_text == ">>> "
      end
    end

    test "returns input as-is when width is too small" do
      segments = [{"Hi", [fg: :white]}]
      assert WordWrap.wrap_segments(segments, 3) == [segments]
    end

    test "handles multiple segments on one line" do
      segments = [
        {"▎ ", [fg: :blue]},
        {"This is a response from the agent that is quite long", [fg: :white]}
      ]

      result = WordWrap.wrap_segments(segments, 25)
      assert length(result) > 1
    end

    test "handles unicode content" do
      segments = [{"日本語テスト 日本語テスト 日本語テスト", [fg: :white]}]
      result = WordWrap.wrap_segments(segments, 15)
      assert result != []
    end

    test "single word exactly at width boundary" do
      segments = [{"exactly10!", [fg: :white]}]
      result = WordWrap.wrap_segments(segments, 10)
      assert result == [[{"exactly10!", [fg: :white]}]]
    end
  end
end
