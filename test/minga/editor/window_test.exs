defmodule Minga.Editor.WindowTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Window

  describe "new/4" do
    test "creates a window with the given id, buffer, and dimensions" do
      buffer = spawn(fn -> :ok end)
      window = Window.new(1, buffer, 24, 80)

      assert window.id == 1
      assert window.buffer == buffer
      assert window.viewport.rows == 24
      assert window.viewport.cols == 80
      assert window.viewport.top == 0
      assert window.viewport.left == 0
    end
  end

  describe "resize/3" do
    test "updates viewport dimensions" do
      buffer = spawn(fn -> :ok end)
      window = Window.new(1, buffer, 24, 80)
      resized = Window.resize(window, 12, 40)

      assert resized.viewport.rows == 12
      assert resized.viewport.cols == 40
      assert resized.id == 1
      assert resized.buffer == buffer
    end
  end
end
