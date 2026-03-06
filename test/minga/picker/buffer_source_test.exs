defmodule Minga.Picker.BufferSourceTest do
  @moduledoc "Tests for BufferSource and BufferAllSource special buffer filtering."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Picker.BufferAllSource
  alias Minga.Picker.BufferSource

  defp start_buffer(opts) do
    {:ok, pid} = BufferServer.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp fake_state(buffers) do
    %{buffers: %{list: buffers}}
  end

  describe "special?/1" do
    test "returns true for *Messages* style names" do
      buf = start_buffer(content: "", buffer_name: "*Messages*")
      assert BufferSource.special?(buf)
    end

    test "returns true for *scratch*" do
      buf = start_buffer(content: "", buffer_name: "*scratch*")
      assert BufferSource.special?(buf)
    end

    test "returns false for file-backed buffers (nil name)" do
      buf = start_buffer(content: "hello")
      refute BufferSource.special?(buf)
    end

    test "returns false for named buffers without star pattern" do
      buf = start_buffer(content: "", buffer_name: "[new 1]")
      refute BufferSource.special?(buf)
    end

    test "returns false for single-star names" do
      buf = start_buffer(content: "", buffer_name: "*oops")
      refute BufferSource.special?(buf)
    end
  end

  describe "candidates/1 (SPC b b)" do
    test "excludes special buffers by default" do
      file_buf = start_buffer(content: "code")
      special_buf = start_buffer(content: "", buffer_name: "*Messages*")

      candidates = BufferSource.candidates(fake_state([file_buf, special_buf]))
      labels = Enum.map(candidates, fn {_idx, label, _desc} -> label end)

      refute Enum.any?(labels, &String.contains?(&1, "*Messages*"))
    end

    test "includes regular named buffers" do
      buf = start_buffer(content: "", buffer_name: "[new 1]")

      candidates = BufferSource.candidates(fake_state([buf]))
      assert length(candidates) == 1
    end

    test "still excludes unlisted buffers" do
      buf = start_buffer(content: "", buffer_name: "hidden", unlisted: true)

      candidates = BufferSource.candidates(fake_state([buf]))
      assert candidates == []
    end
  end

  describe "build_candidates/2 with include_special: true (SPC b B)" do
    test "includes special buffers" do
      file_buf = start_buffer(content: "code")
      special_buf = start_buffer(content: "", buffer_name: "*scratch*")

      candidates =
        BufferSource.build_candidates(fake_state([file_buf, special_buf]), include_special: true)

      labels = Enum.map(candidates, fn {_idx, label, _desc} -> label end)

      assert Enum.any?(labels, &String.contains?(&1, "*scratch*"))
    end

    test "still excludes unlisted buffers even with include_special" do
      unlisted = start_buffer(content: "", buffer_name: "internal", unlisted: true)
      special = start_buffer(content: "", buffer_name: "*Messages*")

      candidates =
        BufferSource.build_candidates(fake_state([unlisted, special]), include_special: true)

      labels = Enum.map(candidates, fn {_idx, label, _desc} -> label end)

      assert length(candidates) == 1
      assert Enum.any?(labels, &String.contains?(&1, "*Messages*"))
    end
  end

  describe "BufferAllSource delegates correctly" do
    test "title indicates all buffers" do
      assert BufferAllSource.title() == "Switch buffer (all)"
    end

    test "preview is enabled" do
      assert BufferAllSource.preview?()
    end

    test "candidates includes special buffers" do
      file_buf = start_buffer(content: "code")
      special_buf = start_buffer(content: "", buffer_name: "*Messages*")

      candidates = BufferAllSource.candidates(fake_state([file_buf, special_buf]))
      labels = Enum.map(candidates, fn {_idx, label, _desc} -> label end)

      assert length(candidates) == 2
      assert Enum.any?(labels, &String.contains?(&1, "*Messages*"))
    end
  end

  describe "edge case: all buffers are special" do
    test "SPC b b returns empty list" do
      scratch = start_buffer(content: "", buffer_name: "*scratch*")
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      candidates = BufferSource.candidates(fake_state([scratch, messages]))
      assert candidates == []
    end

    test "SPC b B still shows them" do
      scratch = start_buffer(content: "", buffer_name: "*scratch*")
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      candidates = BufferAllSource.candidates(fake_state([scratch, messages]))
      assert length(candidates) == 2
    end
  end
end
