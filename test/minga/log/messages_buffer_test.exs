defmodule Minga.Log.MessagesBufferTest do
  @moduledoc """
  Tests for the BEAM-wide singleton `*Messages*` buffer (#1483, #2848).

  Asserts the contract observable from outside any editor: the buffer
  exists as soon as the application is up, log calls reach it before any
  editor starts, and the gateway's `:log_message` topic still works.

  The bounded-append tests (#2848) verify order, line/byte bounds, and
  that append cost does not scale with buffer size.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.Events.LogMessageEvent

  defp unique_tag(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp assert_messages_buffer_contains(tag) do
    :sys.get_state(Minga.Log.MessagesBuffer)
    content = Buffer.content(Minga.Log.messages_buffer())

    assert String.contains?(content, tag),
           "expected #{inspect(tag)} in *Messages*; got:\n#{content}"
  end

  defp assert_log_message_contains(tag) do
    receive do
      {:minga_event, :log_message, %LogMessageEvent{text: message}} ->
        if String.contains?(message, tag) do
          :ok
        else
          assert_log_message_contains(tag)
        end
    after
      500 -> flunk("expected log message containing #{inspect(tag)}")
    end
  end

  describe "singleton lifecycle" do
    test "Minga.Log.messages_buffer/0 returns a pid in headless mode (no editor running)" do
      refute Process.whereis(MingaEditor)
      pid = Minga.Log.messages_buffer()
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "the buffer is unlisted, persistent and read-only" do
      pid = Minga.Log.messages_buffer()
      assert Buffer.unlisted?(pid)
      assert Buffer.persistent?(pid)
      assert Buffer.read_only?(pid)
      assert Buffer.buffer_name(pid) == "*Messages*"
    end
  end

  describe "log routing" do
    test "Minga.Log.* calls land in the shared buffer with no editor running" do
      refute Process.whereis(MingaEditor)
      tag = unique_tag("headless-info")
      Events.subscribe(:log_message)

      try do
        Minga.Log.info(:editor, tag)

        assert_log_message_contains(tag)
        assert_messages_buffer_contains(tag)
      after
        Events.unsubscribe(:log_message)
      end
    end

    test ":log_message broadcasts append to the shared buffer" do
      tag = unique_tag("event-broadcast")

      Events.broadcast(:log_message, %LogMessageEvent{text: tag, level: :info})

      assert_messages_buffer_contains(tag)
    end
  end

  describe "gateway compatibility" do
    test "the gateway's :log_message subscription still receives entries that land in the buffer" do
      tag = unique_tag("gateway-smoke")
      Events.subscribe(:log_message)

      try do
        Events.broadcast(:log_message, %LogMessageEvent{text: tag, level: :warning})

        assert_receive {:minga_event, :log_message,
                        %LogMessageEvent{text: ^tag, level: :warning}},
                       500

        assert_messages_buffer_contains(tag)
      after
        Events.unsubscribe(:log_message)
      end
    end
  end

  describe "bounded_append via Buffer.bounded_append/4" do
    setup do
      {:ok, buf} =
        start_supervised(
          {Buffer, content: "", buffer_name: "test-bounded-#{System.unique_integer([:positive])}"}
        )

      %{buf: buf}
    end

    test "appends text and respects max_lines", %{buf: buf} do
      # Each "\n"-terminated append produces N+1 total lines (N entries + 1
      # trailing empty). Set max_lines to N+1 to retain N content entries.
      for i <- 1..15 do
        Buffer.bounded_append(buf, "line #{i}\n", 11, 100_000)
      end

      content = Buffer.content(buf)
      lines = content |> String.split("\n", trim: true)
      assert length(lines) == 10
      # Oldest lines dropped; newest retained in order
      assert hd(lines) == "line 6"
      assert List.last(lines) == "line 15"
    end

    test "newest entries are in exact order", %{buf: buf} do
      for i <- 1..20 do
        Buffer.bounded_append(buf, "entry-#{i}\n", 6, 100_000)
      end

      content = Buffer.content(buf)
      lines = content |> String.split("\n", trim: true)
      assert lines == ["entry-16", "entry-17", "entry-18", "entry-19", "entry-20"]
    end

    test "respects max_bytes limit", %{buf: buf} do
      # Each line is exactly 11 bytes: "0123456789\n"
      for _ <- 1..100 do
        Buffer.bounded_append(buf, "0123456789\n", 1000, 55)
      end

      content = Buffer.content(buf)
      assert byte_size(content) <= 55
      # At most 5 full lines (5 * 11 = 55 bytes)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) <= 5
    end

    test "byte limit takes precedence when it is more restrictive than line limit", %{buf: buf} do
      # 20-byte lines, max_lines=100 but max_bytes=50
      for i <- 1..10 do
        Buffer.bounded_append(buf, "#{String.pad_leading("#{i}", 18, "x")}\n", 100, 50)
      end

      content = Buffer.content(buf)
      assert byte_size(content) <= 50
    end

    test "does not trim when under both limits", %{buf: buf} do
      Buffer.bounded_append(buf, "hello\n", 100, 100_000)
      Buffer.bounded_append(buf, "world\n", 100, 100_000)

      content = Buffer.content(buf)
      assert content == "hello\nworld\n"
    end

    test "appends at the end and trims the oldest entry when the cursor is at the top", %{
      buf: buf
    } do
      for i <- 1..5, do: Buffer.bounded_append(buf, "entry-#{i}\n", 6, 100_000)
      Buffer.move_to(buf, {0, 0})

      Buffer.bounded_append(buf, "entry-6\n", 6, 100_000)

      assert Buffer.content(buf) == "entry-2\nentry-3\nentry-4\nentry-5\nentry-6\n"
      assert Buffer.cursor(buf) == {0, 0}
    end

    test "a cursor inside the log stays on its entry while entries arrive and old ones drop", %{
      buf: buf
    } do
      for i <- 1..4, do: Buffer.bounded_append(buf, "entry-#{i}\n", 6, 100_000)
      Buffer.move_to(buf, {2, 3})

      Buffer.bounded_append(buf, "entry-5\n", 6, 100_000)
      assert Buffer.cursor(buf) == {2, 3}

      Buffer.bounded_append(buf, "entry-6\n", 6, 100_000)
      assert Buffer.content(buf) == "entry-2\nentry-3\nentry-4\nentry-5\nentry-6\n"
      assert Buffer.cursor(buf) == {1, 3}
    end

    test "a cursor at the end of the log follows new entries", %{buf: buf} do
      for i <- 1..7, do: Buffer.bounded_append(buf, "entry-#{i}\n", 6, 100_000)

      assert Buffer.content(buf) == "entry-3\nentry-4\nentry-5\nentry-6\nentry-7\n"
      assert Buffer.cursor(buf) == {5, 0}
    end

    test "line_count stays within max_lines after many appends", %{buf: buf} do
      for i <- 1..500 do
        Buffer.bounded_append(buf, "msg-#{i}\n", 50, 100_000)
      end

      assert Buffer.line_count(buf) <= 50
    end
  end

  describe "append cost scaling" do
    @tag timeout: 15_000
    test "append time does not grow linearly with buffer size" do
      {:ok, buf} =
        start_supervised(
          {Buffer,
           content: "",
           buffer_name: "test-perf-#{System.unique_integer([:positive])}",
           read_only: true}
        )

      max_lines = 2000
      max_bytes = 500_000

      # Fill buffer to capacity
      for i <- 1..max_lines do
        Buffer.bounded_append(buf, "[00:00:00] boot message #{i}\n", max_lines, max_bytes)
      end

      # Measure time for 100 appends at capacity
      {at_capacity_us, _} =
        :timer.tc(fn ->
          for i <- 1..100 do
            Buffer.bounded_append(
              buf,
              "[00:00:00] at-capacity message #{i}\n",
              max_lines,
              max_bytes
            )
          end
        end)

      # For comparison: 100 appends into a small buffer
      {:ok, small_buf} =
        start_supervised(
          {Buffer,
           content: "",
           buffer_name: "test-perf-small-#{System.unique_integer([:positive])}",
           read_only: true},
          id: :small_buf
        )

      for i <- 1..10 do
        Buffer.bounded_append(small_buf, "[00:00:00] small msg #{i}\n", max_lines, max_bytes)
      end

      {small_us, _} =
        :timer.tc(fn ->
          for i <- 1..100 do
            Buffer.bounded_append(
              small_buf,
              "[00:00:00] small-append message #{i}\n",
              max_lines,
              max_bytes
            )
          end
        end)

      # The bounded offset work is O(max_lines) which is a fixed constant,
      # not O(content_bytes). The ratio between a 2000-line buffer and a
      # 10-line buffer reflects that constant overhead, not unbounded growth.
      # The old O(n) approach (String.split/join on the full content) would
      # produce a ratio well above 50x.
      ratio = at_capacity_us / max(small_us, 1)

      assert ratio < 25,
             "append at capacity (#{at_capacity_us}us) was #{Float.round(ratio, 1)}x " <>
               "slower than small buffer (#{small_us}us); expected < 25x"
    end
  end

  describe "bounds accessors" do
    test "max_lines returns the configured limit" do
      assert Minga.Log.MessagesBuffer.max_lines() == 1000
    end

    test "max_bytes returns the configured limit" do
      assert Minga.Log.MessagesBuffer.max_bytes() == 512_000
    end

    test "max_entry_bytes returns the configured limit" do
      assert Minga.Log.MessagesBuffer.max_entry_bytes() == 8_192
    end
  end
end
