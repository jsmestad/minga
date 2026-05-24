defmodule Minga.Extension.OverlayTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Overlay

  setup do
    on_exit(fn ->
      Overlay.remove_all(:test_extension)
      Overlay.remove_all(:other_extension)
    end)

    :ok
  end

  describe "set/4 and all/0" do
    test "registers an overlay" do
      buf = self()

      :ok =
        Overlay.set(:test_extension, "cursor_1", buf,
          position: {10, 5},
          content: "Claude",
          style: %{fg: 0x7C3AED, opacity: 102},
          shape: :cursor_with_label
        )

      overlays = Overlay.all()
      assert length(overlays) == 1

      [overlay] = overlays
      assert overlay.extension == :test_extension
      assert overlay.overlay_id == "cursor_1"
      assert overlay.buffer == buf
      assert overlay.position == {10, 5}
      assert overlay.content == "Claude"
      assert overlay.shape == :cursor_with_label
    end

    test "replaces overlay with same key" do
      buf = self()
      :ok = Overlay.set(:test_extension, "cursor_1", buf, position: {10, 5}, content: "v1")
      :ok = Overlay.set(:test_extension, "cursor_1", buf, position: {20, 3}, content: "v2")

      overlays = Overlay.all()
      assert length(overlays) == 1
      assert hd(overlays).position == {20, 3}
      assert hd(overlays).content == "v2"
    end

    test "multiple extensions can register overlays" do
      buf = self()
      :ok = Overlay.set(:test_extension, "a", buf, position: {1, 0})
      :ok = Overlay.set(:other_extension, "b", buf, position: {2, 0})

      assert length(Overlay.all()) == 2
    end
  end

  describe "remove/2" do
    test "removes a specific overlay" do
      buf = self()
      :ok = Overlay.set(:test_extension, "a", buf, position: {1, 0})
      :ok = Overlay.set(:test_extension, "b", buf, position: {2, 0})

      :ok = Overlay.remove(:test_extension, "a")

      overlays = Overlay.all()
      assert length(overlays) == 1
      assert hd(overlays).overlay_id == "b"
    end
  end

  describe "remove_all/1" do
    test "removes all overlays for an extension" do
      buf = self()
      :ok = Overlay.set(:test_extension, "a", buf, position: {1, 0})
      :ok = Overlay.set(:test_extension, "b", buf, position: {2, 0})
      :ok = Overlay.set(:other_extension, "c", buf, position: {3, 0})

      :ok = Overlay.remove_all(:test_extension)

      overlays = Overlay.all()
      assert length(overlays) == 1
      assert hd(overlays).extension == :other_extension
    end
  end

  describe "for_buffer/1" do
    test "returns only overlays for the specified buffer" do
      buf1 = spawn(fn -> Process.sleep(:infinity) end)
      buf2 = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Overlay.set(:test_extension, "a", buf1, position: {1, 0})
      :ok = Overlay.set(:test_extension, "b", buf2, position: {2, 0})

      assert length(Overlay.for_buffer(buf1)) == 1
      assert hd(Overlay.for_buffer(buf1)).overlay_id == "a"

      Process.exit(buf1, :kill)
      Process.exit(buf2, :kill)
    end
  end

  describe "unregister_source/1" do
    test "removes all overlays for an extension source" do
      buf = self()
      :ok = Overlay.set(:test_extension, "a", buf, position: {1, 0})
      :ok = Overlay.set(:test_extension, "b", buf, position: {2, 0})

      :ok = Overlay.unregister_source({:extension, :test_extension})

      assert Overlay.all() == []
    end

    test "ignores non-extension sources" do
      buf = self()
      :ok = Overlay.set(:test_extension, "a", buf, position: {1, 0})

      :ok = Overlay.unregister_source(:builtin)

      assert length(Overlay.all()) == 1
    end
  end

  describe "empty?/0" do
    test "returns true when no overlays registered" do
      Overlay.remove_all(:test_extension)
      assert Overlay.empty?()
    end

    test "returns false when overlays exist" do
      :ok = Overlay.set(:test_extension, "a", self(), position: {1, 0})
      refute Overlay.empty?()
    end
  end
end
