defmodule Minga.SnippetTest do
  use ExUnit.Case, async: true

  alias Minga.Snippet

  describe "parse/1" do
    test "plain text returns :plain" do
      assert :plain = Snippet.parse("hello world")
    end

    test "simple tabstop" do
      assert {:ok, %Snippet{text: "", tabstops: [%{index: 1, offset: 0, length: 0}]}} =
               Snippet.parse("$1")
    end

    test "tabstop with placeholder" do
      assert {:ok, %Snippet{text: "name", tabstops: [%{index: 1, placeholder: "name"}]}} =
               Snippet.parse("${1:name}")
    end

    test "multiple tabstops in text" do
      {:ok, snippet} = Snippet.parse("fn ${1:name}(${2:args})")
      assert snippet.text == "fn name(args)"
      assert length(snippet.tabstops) == 2
      [first, second] = snippet.tabstops
      assert first.index == 1
      assert first.placeholder == "name"
      assert second.index == 2
      assert second.placeholder == "args"
    end

    test "tabstops are sorted by index" do
      {:ok, snippet} = Snippet.parse("${2:second} ${1:first} $0")
      indices = Enum.map(snippet.tabstops, & &1.index)
      assert indices == [0, 1, 2]
    end

    test "final cursor position $0" do
      {:ok, snippet} = Snippet.parse("${1:placeholder}$0")
      assert Enum.any?(snippet.tabstops, &(&1.index == 0))
    end

    test "escaped dollar sign" do
      assert :plain = Snippet.parse("cost is \\$5")
    end

    test "text around tabstops" do
      {:ok, snippet} = Snippet.parse("before ${1:mid} after")
      assert snippet.text == "before mid after"
    end
  end
end
