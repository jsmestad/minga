defmodule Minga.Picker.BufferSourceTest do
  @moduledoc "Tests for BufferSource and BufferAllSource special buffer filtering."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State.Buffers
  alias Minga.Picker.BufferAllSource
  alias Minga.Picker.BufferSource
  alias Minga.Picker.Item

  defp start_buffer(opts) do
    {:ok, pid} = BufferServer.start_link(opts)

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  defp fake_state(buffers, opts \\ []) do
    %{
      buffers: %Buffers{
        list: buffers,
        messages: Keyword.get(opts, :messages)
      }
    }
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
      labels = Enum.map(candidates, fn %Item{label: label} -> label end)

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

      labels = Enum.map(candidates, fn %Item{label: label} -> label end)

      assert Enum.any?(labels, &String.contains?(&1, "*scratch*"))
    end

    test "still excludes unlisted buffers even with include_special" do
      unlisted = start_buffer(content: "", buffer_name: "internal", unlisted: true)
      special = start_buffer(content: "", buffer_name: "*Messages*")

      candidates =
        BufferSource.build_candidates(fake_state([unlisted, special]), include_special: true)

      labels = Enum.map(candidates, fn %Item{label: label} -> label end)

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

    test "candidates includes special buffers in the list" do
      file_buf = start_buffer(content: "code")
      special_buf = start_buffer(content: "", buffer_name: "*Messages*")

      candidates = BufferAllSource.candidates(fake_state([file_buf, special_buf]))
      labels = Enum.map(candidates, fn %Item{label: label} -> label end)

      assert length(candidates) == 2
      assert Enum.any?(labels, &String.contains?(&1, "*Messages*"))
    end
  end

  describe "extra special buffers not in list" do
    test "SPC b B includes messages even when not in buffer list" do
      file_buf = start_buffer(content: "code")
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      state = fake_state([file_buf], messages: messages)
      candidates = BufferAllSource.candidates(state)

      labels = Enum.map(candidates, fn %Item{label: label} -> label end)

      assert length(candidates) == 2
      assert Enum.any?(labels, &String.contains?(&1, "*Messages*"))
    end

    test "extra special buffers use {:pid, pid} keys" do
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      state = fake_state([], messages: messages)
      candidates = BufferAllSource.candidates(state)

      assert [%Item{id: key}] = candidates
      assert {:pid, ^messages} = key
    end

    test "does not duplicate special buffers already in the list" do
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      state = fake_state([messages], messages: messages)
      candidates = BufferAllSource.candidates(state)

      assert length(candidates) == 1
    end

    test "SPC b b does not include extra special buffers" do
      file_buf = start_buffer(content: "code")
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      state = fake_state([file_buf], messages: messages)
      candidates = BufferSource.candidates(state)

      labels = Enum.map(candidates, fn %Item{label: label} -> label end)
      assert length(candidates) == 1
      refute Enum.any?(labels, &String.contains?(&1, "*Messages*"))
    end
  end

  describe "unlisted special buffers" do
    test "SPC b B shows unlisted special buffers that are in the list" do
      messages = start_buffer(content: "", buffer_name: "*Messages*", unlisted: true)

      state = fake_state([messages], messages: messages)
      candidates = BufferAllSource.candidates(state)

      labels = Enum.map(candidates, fn %Item{label: label} -> label end)
      assert Enum.any?(labels, &String.contains?(&1, "*Messages*"))
    end

    test "SPC b B shows unlisted special buffers from struct fields" do
      messages =
        start_buffer(content: "", buffer_name: "*Messages*", unlisted: true, persistent: true)

      state = fake_state([], messages: messages)
      candidates = BufferAllSource.candidates(state)

      labels = Enum.map(candidates, fn %Item{label: label} -> label end)
      assert length(candidates) == 1
      assert Enum.any?(labels, &String.contains?(&1, "*Messages*"))
    end

    test "SPC b b still hides unlisted special buffers" do
      messages = start_buffer(content: "", buffer_name: "*Messages*", unlisted: true)

      state = fake_state([messages], messages: messages)
      candidates = BufferSource.candidates(state)

      assert candidates == []
    end

    test "SPC b B still hides unlisted non-special buffers" do
      internal = start_buffer(content: "", buffer_name: "internal", unlisted: true)

      candidates = BufferAllSource.candidates(fake_state([internal]))
      assert candidates == []
    end
  end

  describe "edge case: all buffers are special" do
    test "SPC b b returns empty list even with special buffers on struct" do
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      candidates = BufferSource.candidates(fake_state([], messages: messages))
      assert candidates == []
    end

    test "SPC b B shows special buffers from struct fields" do
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      candidates = BufferAllSource.candidates(fake_state([], messages: messages))

      assert length(candidates) == 1
    end

    test "SPC b B shows special buffers already in the list" do
      messages = start_buffer(content: "", buffer_name: "*Messages*")

      candidates = BufferAllSource.candidates(fake_state([messages]))
      assert length(candidates) == 1
    end
  end
end
