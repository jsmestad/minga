defmodule Minga.LSP.BufferEditTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.LSP.BufferEdit

  test "does not replace more recent buffer content with edits against an older snapshot" do
    buffer = start_supervised!({Buffer.Process, content: "old_name\n"})
    snapshot = Buffer.content_with_version(buffer)
    Buffer.insert_text(buffer, "local_")

    edits = [
      %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 0, "character" => 8}
        },
        "newText" => "new_name"
      }
    ]

    assert {:error, :stale} = BufferEdit.apply(buffer, snapshot, edits, :utf16, :lsp)
    assert Buffer.content(buffer) == "local_old_name\n"
  end
end
