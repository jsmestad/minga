defmodule Minga.Parser.BandwidthTest do
  @moduledoc """
  Verifies that incremental content sync (edit_buffer) uses dramatically
  less IPC bandwidth than full content sync (parse_buffer) for typical
  single-character edits on large files.

  This is the benchmark criterion from #154: "IPC bandwidth for
  single-character edits drops from O(file_size) to O(1)."
  """

  use ExUnit.Case, async: true

  alias Minga.Port.Protocol

  describe "IPC bandwidth comparison" do
    test "edit_buffer is orders of magnitude smaller than parse_buffer for single char insert" do
      # Simulate a 50KB Elixir file
      large_content = String.duplicate("defmodule Mod do\n  def foo, do: :ok\nend\n\n", 1250)
      assert byte_size(large_content) > 50_000

      # Full sync: encode the entire content
      full_sync = Protocol.encode_parse_buffer(0, 1, large_content)
      full_size = byte_size(full_sync)

      # Incremental sync: single character insertion
      edit = %{
        start_byte: 100,
        old_end_byte: 100,
        new_end_byte: 101,
        start_position: {2, 10},
        old_end_position: {2, 10},
        new_end_position: {2, 11},
        inserted_text: "x"
      }

      incremental_sync = Protocol.encode_edit_buffer(0, 1, [edit])
      incremental_size = byte_size(incremental_sync)

      # Full sync should be ~50KB, incremental should be ~50 bytes
      assert full_size > 50_000, "Full sync should be > 50KB, got #{full_size}"

      assert incremental_size < 100,
             "Incremental sync should be < 100 bytes, got #{incremental_size}"

      ratio = div(full_size, incremental_size)

      assert ratio > 500,
             "Expected >500x reduction, got #{ratio}x (#{full_size} vs #{incremental_size})"
    end

    test "edit_buffer is small for multi-character paste" do
      large_content = String.duplicate("line of code\n", 5000)

      full_sync = Protocol.encode_parse_buffer(0, 1, large_content)
      full_size = byte_size(full_sync)

      # Paste 100 characters
      pasted = String.duplicate("x", 100)

      edit = %{
        start_byte: 500,
        old_end_byte: 500,
        new_end_byte: 600,
        start_position: {38, 6},
        old_end_position: {38, 6},
        new_end_position: {38, 106},
        inserted_text: pasted
      }

      incremental_sync = Protocol.encode_edit_buffer(0, 1, [edit])
      incremental_size = byte_size(incremental_sync)

      # Even a 100-char paste should be << full file
      assert incremental_size < 200
      assert full_size > 10 * incremental_size
    end

    test "edit_buffer with deletion is tiny" do
      edit = %{
        start_byte: 1000,
        old_end_byte: 1050,
        new_end_byte: 1000,
        start_position: {20, 0},
        old_end_position: {21, 0},
        new_end_position: {20, 0},
        inserted_text: ""
      }

      deletion_sync = Protocol.encode_edit_buffer(0, 1, [edit])
      # Deletion: no inserted text, just metadata
      assert byte_size(deletion_sync) < 60
    end
  end
end
