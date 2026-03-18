defmodule Minga.LSP.SemanticTokensTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.SemanticTokens

  @token_types ["namespace", "type", "variable", "parameter", "function"]
  @token_modifiers ["declaration", "readonly", "deprecated"]

  describe "decode/3" do
    test "decodes a single token" do
      # Line 0, char 5, length 3, type "variable" (idx 2), no modifiers
      data = [0, 5, 3, 2, 0]
      [token] = SemanticTokens.decode(data, @token_types, @token_modifiers)

      assert token.line == 0
      assert token.start_char == 5
      assert token.length == 3
      assert token.type == "variable"
      assert token.modifiers == []
    end

    test "decodes delta-encoded positions" do
      data = [
        # Token 1: line 0, char 5, len 3, type variable
        0,
        5,
        3,
        2,
        0,
        # Token 2: same line, char 10 (delta 5 from char 5), len 4, type function
        0,
        5,
        4,
        4,
        0,
        # Token 3: next line (delta 1), char 2, len 6, type type
        1,
        2,
        6,
        1,
        0
      ]

      tokens = SemanticTokens.decode(data, @token_types, @token_modifiers)
      assert length(tokens) == 3

      [t1, t2, t3] = tokens
      assert {t1.line, t1.start_char} == {0, 5}
      assert {t2.line, t2.start_char} == {0, 10}
      assert {t3.line, t3.start_char} == {1, 2}
    end

    test "delta start resets on new line" do
      data = [
        # Line 0, char 10
        0,
        10,
        3,
        0,
        0,
        # Line 2 (delta 2), char 5 (absolute, not relative to 10)
        2,
        5,
        3,
        0,
        0
      ]

      tokens = SemanticTokens.decode(data, @token_types, @token_modifiers)
      [t1, t2] = tokens
      assert {t1.line, t1.start_char} == {0, 10}
      assert {t2.line, t2.start_char} == {2, 5}
    end

    test "decodes modifier bitmask" do
      # Modifiers: declaration (bit 0) + deprecated (bit 2) = 0b101 = 5
      data = [0, 0, 3, 2, 5]
      [token] = SemanticTokens.decode(data, @token_types, @token_modifiers)

      assert token.modifiers == ["declaration", "deprecated"]
    end

    test "handles unknown type index gracefully" do
      data = [0, 0, 3, 99, 0]
      [token] = SemanticTokens.decode(data, @token_types, @token_modifiers)

      assert token.type == "unknown"
    end

    test "empty data returns empty list" do
      assert SemanticTokens.decode([], @token_types, @token_modifiers) == []
    end

    test "incomplete group is ignored" do
      # Only 3 integers, not a complete group of 5
      data = [0, 5, 3]
      assert SemanticTokens.decode(data, @token_types, @token_modifiers) == []
    end
  end

  describe "to_spans/5" do
    # Helper: line text lookup for ASCII test content
    defp ascii_line_fn(lines) do
      fn line_num -> Enum.at(lines, line_num, "") end
    end

    test "converts tokens to highlight spans at layer 2" do
      tokens = [
        %{line: 0, start_char: 4, length: 3, type: "variable", modifiers: []}
      ]

      offsets = %{0 => 0}

      name_to_id = fn
        "@lsp.type.variable" -> 0
        _ -> 99
      end

      spans =
        SemanticTokens.to_spans(
          tokens,
          offsets,
          name_to_id,
          ascii_line_fn(["def foo bar"]),
          :utf8
        )

      assert [span] = spans
      assert span.start_byte == 4
      assert span.end_byte == 7
      assert span.capture_id == 0
      assert span.layer == 2
    end

    test "tokens with modifiers produce a single composite span" do
      tokens = [
        %{line: 0, start_char: 0, length: 5, type: "function", modifiers: ["deprecated"]}
      ]

      offsets = %{0 => 0}

      name_to_id = fn
        "@lsp.type.function+deprecated" -> 0
        _ -> 99
      end

      spans =
        SemanticTokens.to_spans(
          tokens,
          offsets,
          name_to_id,
          ascii_line_fn(["hello_world"]),
          :utf8
        )

      # Single composite span, not separate type + modifier spans
      assert length(spans) == 1
      [span] = spans
      assert span.capture_id == 0
      assert span.layer == 2
    end

    test "multi-line tokens use correct byte offsets" do
      tokens = [
        %{line: 0, start_char: 0, length: 3, type: "variable", modifiers: []},
        %{line: 2, start_char: 4, length: 5, type: "function", modifiers: []}
      ]

      # Line 0: byte 0, Line 1: byte 10, Line 2: byte 20
      offsets = %{0 => 0, 1 => 10, 2 => 20}

      name_to_id = fn
        "@lsp.type.variable" -> 0
        "@lsp.type.function" -> 1
        _ -> 99
      end

      lines = ["first_line", "second_lin", "    function_call"]

      spans =
        SemanticTokens.to_spans(tokens, offsets, name_to_id, ascii_line_fn(lines), :utf8)

      assert [s1, s2] = spans
      assert {s1.start_byte, s1.end_byte} == {0, 3}
      assert {s2.start_byte, s2.end_byte} == {24, 29}
    end

    test "handles UTF-16 encoding correctly with multi-byte characters" do
      # Line: "café" — the é is 2 bytes in UTF-8 but 1 UTF-16 code unit
      # If LSP says start_char=3 (UTF-16 units), that's the 'é' character
      # which is at byte offset 3 in UTF-8 (c=1, a=1, f=1, é=2)
      tokens = [
        %{line: 0, start_char: 3, length: 1, type: "variable", modifiers: []}
      ]

      offsets = %{0 => 0}

      name_to_id = fn _ -> 0 end

      spans =
        SemanticTokens.to_spans(
          tokens,
          offsets,
          name_to_id,
          ascii_line_fn(["café"]),
          :utf16
        )

      assert [span] = spans
      # UTF-16 char 3 = byte 3 (é starts at byte 3, is 2 bytes)
      assert span.start_byte == 3
      # UTF-16 char 4 = byte 5 (past the 2-byte é)
      assert span.end_byte == 5
    end
  end

  describe "extract_legend/1" do
    test "extracts legend from server capabilities" do
      caps = %{
        "semanticTokensProvider" => %{
          "legend" => %{
            "tokenTypes" => ["namespace", "type"],
            "tokenModifiers" => ["declaration"]
          },
          "full" => true
        }
      }

      assert {["namespace", "type"], ["declaration"]} = SemanticTokens.extract_legend(caps)
    end

    test "returns :not_supported when no semantic tokens" do
      assert :not_supported == SemanticTokens.extract_legend(%{})
    end

    test "returns :not_supported when legend is incomplete" do
      caps = %{
        "semanticTokensProvider" => %{
          "legend" => %{"tokenTypes" => ["namespace"]}
        }
      }

      assert :not_supported == SemanticTokens.extract_legend(caps)
    end
  end

  describe "capture_name/1 and modifier_capture_name/1" do
    test "formats type capture names" do
      assert SemanticTokens.capture_name("variable") == "@lsp.type.variable"
      assert SemanticTokens.capture_name("function") == "@lsp.type.function"
    end

    test "formats modifier capture names" do
      assert SemanticTokens.modifier_capture_name("readonly") == "@lsp.mod.readonly"
      assert SemanticTokens.modifier_capture_name("deprecated") == "@lsp.mod.deprecated"
    end
  end
end
