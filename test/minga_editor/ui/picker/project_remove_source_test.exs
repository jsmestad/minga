defmodule MingaEditor.UI.Picker.ProjectRemoveSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.ProjectRemoveSource

  describe "confirmation_label/1" do
    test "keeps the GUI minibuffer prompt within the protocol byte limit" do
      long_name = String.duplicate("a", 255)
      label = ProjectRemoveSource.confirmation_label(Path.join("/tmp", long_name))

      assert byte_size(label) <= 255
      assert String.starts_with?(label, "Remove ")
      assert String.ends_with?(label, "? (y/n): ")
      assert String.contains?(label, "…")
    end

    test "does not split multibyte graphemes when truncating" do
      long_name = String.duplicate("界", 100)
      label = ProjectRemoveSource.confirmation_label(Path.join("/tmp", long_name))

      assert byte_size(label) <= 255
      assert String.valid?(label)
      assert String.contains?(label, "…")
    end
  end
end
