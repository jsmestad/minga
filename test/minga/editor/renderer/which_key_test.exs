defmodule Minga.Editor.Renderer.WhichKeyTest do
  @moduledoc """
  Tests for no-buffer splash screen rendering (orchestrator-level tests that
  don't fit cleanly into a single sub-module).
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Test.HeadlessPort

  describe "no file open" do
    test "shows splash screen when no buffer is loaded" do
      id = :erlang.unique_integer([:positive])
      {:ok, port} = HeadlessPort.start_link(width: 80, height: 24)

      {:ok, editor} =
        Minga.Editor.start_link(
          name: :"headless_nofile_#{id}",
          port_manager: port,
          buffer: nil,
          width: 80,
          height: 24
        )

      send(editor, {:minga_input, {:ready, 80, 24}})
      :ok = HeadlessPort.await_frame(port)

      row0 = HeadlessPort.get_row_text(port, 0)
      assert String.contains?(row0, "Minga")
    end
  end
end
