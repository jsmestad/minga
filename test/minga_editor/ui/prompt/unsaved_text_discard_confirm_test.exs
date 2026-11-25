defmodule MingaEditor.UI.Prompt.UnsavedTextDiscardConfirmTest do
  @moduledoc "The discard prompt says what is deleted and that it cannot be undone, and fits the frontends' prompt limit."

  use ExUnit.Case, async: true

  alias MingaEditor.UI.Prompt.UnsavedTextDiscardConfirm

  defp entry(path, lines), do: %{path: path, swap_path: "/swap/x.swap", lines: lines}

  test "the prompt names the file, the amount of text and that it cannot be undone" do
    assert UnsavedTextDiscardConfirm.label(entry("/work/alpha/lib/a.ex", 12)) ==
             "Delete the unsaved text of a.ex (12 lines)? It cannot be undone. (y/n): "

    assert UnsavedTextDiscardConfirm.label(entry("/work/alpha/lib/a.ex", 1)) =~ "(1 line)?"
  end

  test "a long file name is shortened so the prompt stays within the protocol limit" do
    for name <- [String.duplicate("a", 300), String.duplicate("界", 120)] do
      label = UnsavedTextDiscardConfirm.label(entry(Path.join("/tmp", name), 3))

      assert byte_size(label) <= 255
      assert String.valid?(label)
      assert label =~ "…"
      assert String.ends_with?(label, "(3 lines)? It cannot be undone. (y/n): ")
    end
  end
end
