defmodule Minga.Buffer.ReplaceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.Replace

  describe "apply/4" do
    test "replaces text with one clear target" do
      doc = Document.new("hello world")

      assert {:ok, new_doc, "applied"} = Replace.apply(doc, "hello", "goodbye")
      assert Document.content(new_doc) == "goodbye world"
    end

    test "rejects missing, empty, and ambiguous matches" do
      doc = Document.new("foo bar foo")

      assert {:error, "old_text not found"} = Replace.apply(doc, "missing", "x")
      assert {:error, "old_text is empty"} = Replace.apply(doc, "", "x")
      assert {:error, msg} = Replace.apply(doc, "foo", "x")
      assert msg =~ "2 times"
    end

    test "enforces line boundaries against the replacement target" do
      doc = Document.new("line1\ntarget\nline3")

      assert {:error, msg} = Replace.apply(doc, "target", "changed", {0, 0})
      assert msg =~ "edit outside boundary"

      assert {:ok, new_doc, "applied"} = Replace.apply(doc, "target", "changed", {1, 1})
      assert Document.content(new_doc) == "line1\nchanged\nline3"
    end
  end

  describe "apply_batch/3" do
    test "applies edits sequentially and reports per-edit results" do
      doc = Document.new("one two three")

      {new_doc, results, any_applied?} =
        Replace.apply_batch(doc, [{"one", "1"}, {"missing", "x"}, {"three", "3"}])

      assert any_applied?
      assert results == [{:ok, "applied"}, {:error, "old_text not found"}, {:ok, "applied"}]
      assert Document.content(new_doc) == "1 two 3"
    end

    test "keeps the document unchanged when every edit fails" do
      doc = Document.new("hello")

      {new_doc, results, any_applied?} = Replace.apply_batch(doc, [{"missing", "x"}, {"", "y"}])

      refute any_applied?
      assert results == [{:error, "old_text not found"}, {:error, "old_text is empty"}]
      assert Document.content(new_doc) == "hello"
    end
  end
end
