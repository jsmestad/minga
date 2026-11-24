defmodule Minga.Core.PluralTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Plural

  doctest Minga.Core.Plural

  describe "count/3" do
    test "only a count of one takes the singular noun" do
      labels = Enum.map([0, 1, 2, 11, 21], &Plural.count(&1, "line", "lines"))

      assert labels == ["0 lines", "1 line", "2 lines", "11 lines", "21 lines"]
    end

    test "irregular nouns use the forms the caller passes" do
      assert Plural.count(1, "match", "matches") == "1 match"
      assert Plural.count(2, "match", "matches") == "2 matches"
    end
  end

  describe "noun/3" do
    test "returns the noun without the count" do
      assert Plural.noun(1, "file", "files") == "file"
      assert Plural.noun(0, "file", "files") == "files"
    end
  end
end
