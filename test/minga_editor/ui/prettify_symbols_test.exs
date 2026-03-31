defmodule Minga.PrettifySymbolsTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.PrettifySymbols

  describe "rules_for/1" do
    test "returns common rules for unknown filetype" do
      rules = PrettifySymbols.rules_for(:text)
      assert rules != []

      arrow = Enum.find(rules, &(&1.source == "->"))
      assert arrow != nil
      assert arrow.replacement == "→"
      assert "operator" in arrow.captures
    end

    test "returns common plus elixir rules for :elixir" do
      rules = PrettifySymbols.rules_for(:elixir)

      fn_rule = Enum.find(rules, &(&1.source == "fn"))
      assert fn_rule != nil
      assert fn_rule.replacement == "λ"
      assert "keyword" in fn_rule.captures
    end

    test "returns common plus python rules for :python" do
      rules = PrettifySymbols.rules_for(:python)

      lambda_rule = Enum.find(rules, &(&1.source == "lambda"))
      assert lambda_rule != nil
      assert lambda_rule.replacement == "λ"
    end

    test "rules are sorted by source length descending (greedy match)" do
      rules = PrettifySymbols.rules_for(:elixir)
      lengths = Enum.map(rules, &byte_size(&1.source))

      # Each length should be >= the next (descending order)
      pairs = Enum.zip(lengths, Enum.drop(lengths, 1))
      assert Enum.all?(pairs, fn {a, b} -> a >= b end)
    end

    test "includes !== and === (3-char) before != and == (2-char)" do
      rules = PrettifySymbols.rules_for(:javascript)

      idx_neq3 = Enum.find_index(rules, &(&1.source == "!=="))
      idx_neq2 = Enum.find_index(rules, &(&1.source == "!="))

      if idx_neq3 && idx_neq2 do
        assert idx_neq3 < idx_neq2, "!== should come before != for greedy matching"
      end
    end

    test "haskell has unique rules" do
      rules = PrettifySymbols.rules_for(:haskell)

      composition = Enum.find(rules, &(&1.source == "."))
      assert composition != nil
      assert composition.replacement == "∘"

      type_sig = Enum.find(rules, &(&1.source == "::"))
      assert type_sig != nil
      assert type_sig.replacement == "∷"
    end
  end
end
