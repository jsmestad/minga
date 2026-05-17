defmodule Minga.Editing.BlockPairTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.BlockPair
  alias Minga.Language.Bash
  alias Minga.Language.BlockPair, as: BlockPairSpec
  alias Minga.Language.Elixir, as: ElixirLang
  alias Minga.Language.Ruby

  describe "closing_for/2" do
    test "returns Elixir block closers" do
      pairs = ElixirLang.block_pairs()

      assert BlockPair.closing_for(pairs, "def run do") == "end"
      assert BlockPair.closing_for(pairs, "  if ok? do  ") == "end"
      assert BlockPair.closing_for(pairs, "fn") == "end"
      assert BlockPair.closing_for(pairs, "fn ->") == "end"
      assert BlockPair.closing_for(pairs, "fn item ->") == "end"
    end

    test "returns Ruby block closers" do
      pairs = Ruby.block_pairs()

      assert BlockPair.closing_for(pairs, "def run") == "end"
      assert BlockPair.closing_for(pairs, "class User") == "end"
      assert BlockPair.closing_for(pairs, "module Billing") == "end"
      assert BlockPair.closing_for(pairs, "if enabled") == "end"
      assert BlockPair.closing_for(pairs, "items.each do") == "end"
      assert BlockPair.closing_for(pairs, "items.each do |item|") == "end"
    end

    test "returns shell block closers" do
      pairs = Bash.block_pairs()

      assert BlockPair.closing_for(pairs, "if test -f mix.exs") == "fi"
      assert BlockPair.closing_for(pairs, "for file in *.ex; do") == "done"
      assert BlockPair.closing_for(pairs, "case $arg in") == "esac"
    end

    test "rejects modifier and non-opening forms" do
      ruby_pairs = Ruby.block_pairs()
      elixir_pairs = ElixirLang.block_pairs()
      bash_pairs = Bash.block_pairs()

      assert BlockPair.closing_for(ruby_pairs, "return x if cond") == nil
      assert BlockPair.closing_for(ruby_pairs, "endif") == nil
      assert BlockPair.closing_for(elixir_pairs, "todo") == nil
      assert BlockPair.closing_for(bash_pairs, "done") == nil
      assert BlockPair.closing_for([], "if cond") == nil
    end

    test "uses caller-provided language metadata" do
      pairs = [BlockPairSpec.new("while", "wend", :line_head)]

      assert BlockPair.closing_for(pairs, "while active") == "wend"
    end
  end
end
