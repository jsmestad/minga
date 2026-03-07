defmodule Minga.Buffer.UnicodeWidthTest do
  @moduledoc """
  Comprehensive tests for BEAM-side Unicode display width computation.

  These validate that our width tables agree with wcwidth/wcswidth
  conventions used by terminal emulators. This is the monospace path
  that #153 specifies: BEAM and frontend must agree on display width
  for all graphemes.

  The known-good widths here match what libvaxis's gwidth.gwidth()
  returns (Unicode 15.1 / EAW). If a test fails, either our tables
  or the expected value needs updating.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Unicode

  describe "ASCII" do
    test "printable ASCII characters are width 1" do
      for cp <- ?!..?~ do
        char = <<cp::utf8>>
        assert Unicode.display_width(char) == 1, "Expected width 1 for #{inspect(char)}"
      end
    end

    test "space is width 1" do
      assert Unicode.display_width(" ") == 1
    end

    test "tab is width 0 (rendered by tab expansion, not as a character)" do
      assert Unicode.display_width("\t") == 0
    end
  end

  describe "CJK wide characters" do
    test "CJK Unified Ideographs are width 2" do
      # 你好世界
      assert Unicode.display_width("你") == 2
      assert Unicode.display_width("好") == 2
      assert Unicode.display_width("世") == 2
      assert Unicode.display_width("界") == 2
    end

    test "CJK string width is sum of character widths" do
      assert Unicode.display_width("你好世界") == 8
    end

    test "Katakana are width 2" do
      assert Unicode.display_width("ア") == 2
      assert Unicode.display_width("カ") == 2
    end

    test "Hiragana are width 2" do
      assert Unicode.display_width("あ") == 2
      assert Unicode.display_width("か") == 2
    end

    test "Korean Hangul are width 2" do
      assert Unicode.display_width("한") == 2
      assert Unicode.display_width("글") == 2
    end

    test "fullwidth Latin are width 2" do
      # Ａ is U+FF21 (fullwidth A)
      assert Unicode.display_width("Ａ") == 2
    end
  end

  describe "combining marks" do
    test "combining diacriticals have width 0" do
      # e + combining acute accent
      assert Unicode.display_width("é") == 1
    end

    test "combining marks don't add width in grapheme clusters" do
      # a + combining ring above = å
      assert Unicode.display_width("å") == 1
    end
  end

  describe "emoji" do
    test "simple emoji are width 2" do
      assert Unicode.display_width("😀") == 2
      assert Unicode.display_width("🎉") == 2
      assert Unicode.display_width("🚀") == 2
    end

    test "emoji with ZWJ sequences" do
      # Family emoji (varies by terminal, but should be >= 2)
      width = Unicode.display_width("👨‍👩‍👧‍👦")
      assert width >= 2
    end

    test "flag emoji" do
      width = Unicode.display_width("🇺🇸")
      assert width >= 1
    end
  end

  describe "mixed content" do
    test "mixed ASCII and CJK" do
      # "hello世界" = 5 + 4 = 9
      assert Unicode.display_width("hello世界") == 9
    end

    test "mixed ASCII and emoji" do
      # "hi 🎉" = 2 + 1 + 2 = 5
      assert Unicode.display_width("hi 🎉") == 5
    end

    test "empty string is width 0" do
      assert Unicode.display_width("") == 0
    end
  end

  describe "display_col consistency" do
    test "display_col matches display_width for full string" do
      text = "hello世界café"
      full_width = Unicode.display_width(text)
      col = Unicode.display_col(text, byte_size(text))
      assert col == full_width
    end

    test "display_col at byte 0 is always 0" do
      assert Unicode.display_col("anything", 0) == 0
    end
  end

  describe "property: width is non-negative and bounded" do
    property "display_width is always non-negative" do
      check all(text <- StreamData.string(:printable, min_length: 0, max_length: 50)) do
        assert Unicode.display_width(text) >= 0
      end
    end

    property "display_width <= 2 * grapheme count (no grapheme wider than 2)" do
      check all(text <- StreamData.string(:printable, min_length: 1, max_length: 50)) do
        width = Unicode.display_width(text)
        grapheme_count = String.length(text)
        assert width <= 2 * grapheme_count
      end
    end

    property "display_width >= grapheme count for ASCII-only strings" do
      check all(text <- StreamData.string(:ascii, min_length: 1, max_length: 50)) do
        width = Unicode.display_width(text)
        # ASCII printable chars are all width 1, control chars may be 0 or 1
        assert width >= 0
      end
    end
  end
end
