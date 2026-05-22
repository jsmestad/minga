defmodule Minga.Keymap.SigilTest do
  use ExUnit.Case, async: true

  import Minga.Keymap.Sigil

  doctest Minga.Keymap.Sigil

  describe "~k" do
    test "parses a single key" do
      assert ~k(a) == [{?a, 0}]
    end

    test "parses a multi-key sequence" do
      assert ~k(s p) == [{?s, 0}, {?p, 0}]
    end

    test "parses modifier tokens" do
      assert ~k(C-d M-x C-S-a) == [{?d, 0x02}, {?x, 0x04}, {?a, 0x03}]
    end

    test "parses named keys" do
      assert ~k(SPC TAB RET ESC DEL) == [{32, 0}, {9, 0}, {13, 0}, {27, 0}, {127, 0}]
    end

    test "parses punctuation literals used by converted keymaps" do
      assert ~k(: ? " ' ` [ ] { } ~) ==
               Enum.map([58, 63, 34, 39, 96, 91, 93, 123, 125, 126], &{&1, 0})
    end

    test "parses uppercase letters" do
      assert ~k(A Z) == [{?A, 0}, {?Z, 0}]
    end

    test "raises at compile time for invalid tokens" do
      assert_raise ArgumentError, ~r/invalid key sequence "INVALID"/, fn ->
        Code.compile_string("""
        defmodule Minga.Keymap.SigilInvalidTokenTest do
          import Minga.Keymap.Sigil
          @bad ~k(INVALID)
        end
        """)
      end
    end

    test "raises at compile time for sigil modifiers" do
      assert_raise ArgumentError, ~r/~k does not support sigil modifiers/, fn ->
        Code.compile_string("""
        defmodule Minga.Keymap.SigilModifierTest do
          import Minga.Keymap.Sigil
          @bad ~k(a)z
        end
        """)
      end
    end

    test "raises at compile time for non-literal input" do
      assert_raise ArgumentError, fn ->
        source =
          [
            "defmodule Minga.Keymap.SigilNonLiteralKTest do",
            "  import Minga.Keymap.Sigil",
            "  parts = [\"a\"]",
            "  @bad ~k[" <> "#" <> "{Enum.join(parts, \" \")}]",
            "end"
          ]
          |> Enum.join("\n")

        Code.compile_string(source)
      end
    end
  end

  describe "~K" do
    test "parses a single key" do
      assert ~K(a) == {?a, 0}
    end

    test "parses a modifier key" do
      assert ~K(C-d) == {?d, 0x02}
    end

    test "parses a named key" do
      assert ~K(SPC) == {32, 0}
    end

    test "rejects multi-key input" do
      assert_raise ArgumentError,
                   ~r/~K requires exactly one key, but "s p" parsed to 2 keys/,
                   fn ->
                     Code.compile_string("""
                     defmodule Minga.Keymap.SigilMultiKeyTest do
                       import Minga.Keymap.Sigil
                       @bad ~K(s p)
                     end
                     """)
                   end
    end

    test "rejects empty input" do
      assert_raise ArgumentError,
                   ~r/~K requires exactly one key, but "" parsed to zero keys/,
                   fn ->
                     Code.compile_string("""
                     defmodule Minga.Keymap.SigilEmptyTest do
                       import Minga.Keymap.Sigil
                       @bad ~K()
                     end
                     """)
                   end
    end

    test "rejects sigil modifiers" do
      assert_raise ArgumentError, ~r/~K does not support sigil modifiers/, fn ->
        Code.compile_string("""
        defmodule Minga.Keymap.SigilModifierKTest do
          import Minga.Keymap.Sigil
          @bad ~K(a)z
        end
        """)
      end
    end

    test "raises at compile time for non-literal input" do
      assert_raise ArgumentError, fn ->
        source =
          [
            "defmodule Minga.Keymap.SigilNonLiteralKSingleTest do",
            "  import Minga.Keymap.Sigil",
            "  parts = [\"a\"]",
            "  @bad ~K[" <> "#" <> "{Enum.join(parts, \" \")}]",
            "end"
          ]
          |> Enum.join("\n")

        Code.compile_string(source)
      end
    end
  end
end
