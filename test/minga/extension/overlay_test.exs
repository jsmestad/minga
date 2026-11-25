defmodule Minga.Extension.OverlayTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Overlay

  # Each test owns its table.
  # An overlay set in the application's table reaches every editor state that reads that table, in any test.
  setup do
    table = Module.concat(__MODULE__, "Table#{System.unique_integer([:positive])}")
    start_supervised!({Overlay, name: table})
    %{table: table}
  end

  describe "set/5 and all/1" do
    test "registers an overlay", %{table: table} do
      buf = self()

      :ok =
        Overlay.set(table, :test_extension, "cursor_1", buf,
          position: {10, 5},
          content: "Claude",
          style: %{fg: 0x7C3AED, opacity: 102},
          shape: :cursor_with_label
        )

      overlays = Overlay.all(table)
      assert Enum.count(overlays) == 1

      [overlay] = overlays
      assert overlay.extension == :test_extension
      assert overlay.overlay_id == "cursor_1"
      assert overlay.buffer == buf
      assert overlay.position == {10, 5}
      assert overlay.content == "Claude"
      assert overlay.shape == :cursor_with_label
    end

    test "replaces overlay with same key", %{table: table} do
      buf = self()
      :ok = Overlay.set(table, :test_extension, "cursor_1", buf, position: {10, 5}, content: "v1")
      :ok = Overlay.set(table, :test_extension, "cursor_1", buf, position: {20, 3}, content: "v2")

      overlays = Overlay.all(table)
      assert Enum.count(overlays) == 1
      assert hd(overlays).position == {20, 3}
      assert hd(overlays).content == "v2"
    end

    test "multiple extensions can register overlays", %{table: table} do
      buf = self()
      :ok = Overlay.set(table, :test_extension, "a", buf, position: {1, 0})
      :ok = Overlay.set(table, :other_extension, "b", buf, position: {2, 0})

      assert Enum.count(Overlay.all(table)) == 2
    end
  end

  describe "remove/3" do
    test "removes a specific overlay", %{table: table} do
      buf = self()
      :ok = Overlay.set(table, :test_extension, "a", buf, position: {1, 0})
      :ok = Overlay.set(table, :test_extension, "b", buf, position: {2, 0})

      :ok = Overlay.remove(table, :test_extension, "a")

      overlays = Overlay.all(table)
      assert Enum.count(overlays) == 1
      assert hd(overlays).overlay_id == "b"
    end
  end

  describe "remove_all/2" do
    test "removes all overlays for an extension", %{table: table} do
      buf = self()
      :ok = Overlay.set(table, :test_extension, "a", buf, position: {1, 0})
      :ok = Overlay.set(table, :test_extension, "b", buf, position: {2, 0})
      :ok = Overlay.set(table, :other_extension, "c", buf, position: {3, 0})

      :ok = Overlay.remove_all(table, :test_extension)

      overlays = Overlay.all(table)
      assert Enum.count(overlays) == 1
      assert hd(overlays).extension == :other_extension
    end
  end

  describe "for_buffer/2" do
    test "returns only overlays for the specified buffer", %{table: table} do
      buf1 = spawn(fn -> Process.sleep(:infinity) end)
      buf2 = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Overlay.set(table, :test_extension, "a", buf1, position: {1, 0})
      :ok = Overlay.set(table, :test_extension, "b", buf2, position: {2, 0})

      assert Enum.count(Overlay.for_buffer(table, buf1)) == 1
      assert hd(Overlay.for_buffer(table, buf1)).overlay_id == "a"

      Process.exit(buf1, :kill)
      Process.exit(buf2, :kill)
    end
  end

  describe "unregister_source/2" do
    test "removes all overlays for an extension source", %{table: table} do
      buf = self()
      :ok = Overlay.set(table, :test_extension, "a", buf, position: {1, 0})
      :ok = Overlay.set(table, :test_extension, "b", buf, position: {2, 0})

      :ok = Overlay.unregister_source(table, {:extension, :test_extension})

      assert Overlay.all(table) == []
    end

    test "ignores non-extension sources", %{table: table} do
      buf = self()
      :ok = Overlay.set(table, :test_extension, "a", buf, position: {1, 0})

      :ok = Overlay.unregister_source(table, :builtin)

      assert Enum.count(Overlay.all(table)) == 1
    end
  end

  describe "empty?/1" do
    test "returns true when no overlays registered", %{table: table} do
      Overlay.remove_all(table, :test_extension)
      assert Overlay.empty?(table)
    end

    test "returns false when overlays exist", %{table: table} do
      :ok = Overlay.set(table, :test_extension, "a", self(), position: {1, 0})
      refute Overlay.empty?(table)
    end
  end
end
