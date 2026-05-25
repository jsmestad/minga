defmodule Minga.Buffer.UndoPatchTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.Operation
  alias Minga.Buffer.UndoPatch

  defp doc(text), do: Document.new(text)

  describe "from_delta/2" do
    test "captures insertion patches" do
      old_doc = doc("hello")
      {:edited, new_doc, delta} = Operation.insert_at_cursor(old_doc, "X")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.start_byte == 0
      assert patch.old_text == ""
      assert patch.new_text == "X"
      assert UndoPatch.apply(patch, new_doc) |> Document.content() == "hello"
    end

    test "captures deletion patches" do
      old_doc = doc("héllo") |> Document.move_to({0, 3})
      {:edited, new_doc, delta} = Operation.backspace(old_doc)

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "é"
      assert patch.new_text == ""
      assert UndoPatch.apply(patch, new_doc) |> Document.content() == "héllo"
    end

    test "captures replacement patches" do
      old_doc = doc("one two three")
      {:edited, new_doc, delta} = Operation.replace_range(old_doc, {0, 4}, {0, 6}, "TWO")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "two"
      assert patch.new_text == "TWO"
      assert UndoPatch.apply(patch, new_doc) |> Document.content() == "one two three"
    end

    test "captures deleted text across the cursor gap" do
      old_doc = doc("abc def") |> Document.move_to({0, 4})
      {:edited, new_doc, delta} = Operation.replace_range(old_doc, {0, 2}, {0, 4}, "X")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "c d"
      assert patch.new_text == "X"
      assert UndoPatch.apply(patch, new_doc) |> Document.content() == "abc def"
    end

    test "owns deleted slices instead of retaining the original large document binary" do
      prefix = String.duplicate("a", 1_000_000)
      old_doc = doc(prefix <> "TARGET")

      {:edited, _new_doc, delta} =
        Operation.replace_range(old_doc, {0, byte_size(prefix)}, {0, byte_size(prefix) + 5}, "x")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "TARGET"
      assert :binary.referenced_byte_size(patch.old_text) == byte_size(patch.old_text)
    end
  end

  describe "invert/2" do
    test "inverted patch reapplies the original edit" do
      old_doc = doc("hello")
      {:edited, new_doc, delta} = Operation.insert_at_cursor(old_doc, "X")
      patch = UndoPatch.from_delta(delta, old_doc)
      inverse = UndoPatch.invert(patch, new_doc)

      restored = UndoPatch.apply(patch, new_doc)
      redone = UndoPatch.apply(inverse, restored)

      assert Document.content(redone) == "Xhello"
      assert Document.cursor(redone) == Document.cursor(new_doc)
    end
  end

  describe "from_documents/2" do
    test "stores only the changed byte range" do
      patch = UndoPatch.from_documents(doc("prefix old suffix"), doc("prefix new suffix"))

      assert patch.start_byte == byte_size("prefix ")
      assert patch.old_text == "old"
      assert patch.new_text == "new"
    end

    test "stores byte fragments for multi-byte replacements" do
      patch = UndoPatch.from_documents(doc("é"), doc("è"))

      assert patch.old_text == <<0xA9>>
      assert patch.new_text == <<0xA8>>
      refute String.valid?(patch.old_text)
      refute String.valid?(patch.new_text)
      assert Document.content(UndoPatch.apply(patch, doc("è"))) == "é"
    end

    test "large document patch size stays proportional to the changed slice" do
      prefix = String.duplicate("a", 100_000)
      suffix = String.duplicate("z", 100_000)

      patch =
        UndoPatch.from_documents(doc(prefix <> "old" <> suffix), doc(prefix <> "new" <> suffix))

      assert patch.start_byte == byte_size(prefix)
      assert patch.old_text == "old"
      assert patch.new_text == "new"
      assert byte_size(patch.old_text) + byte_size(patch.new_text) == 6
    end

    test "handles mid-buffer cursor gaps with unicode near the diff" do
      old_doc = doc("αβγδ") |> Document.move_to({0, 4})
      new_doc = doc("αβξδ") |> Document.move_to({0, 4})

      patch = UndoPatch.from_documents(old_doc, new_doc)

      assert patch.start_byte == 5
      assert byte_size(patch.old_text) == 1
      assert byte_size(patch.new_text) == 1
      refute String.valid?(patch.old_text)
      refute String.valid?(patch.new_text)
      assert Document.content(UndoPatch.apply(patch, new_doc)) == "αβγδ"
    end
  end
end
