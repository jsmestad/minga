defmodule Minga.Buffer.MessagesTest do
  @moduledoc """
  Tests for the BEAM-wide singleton `*Messages*` buffer (#1483).

  Asserts the contract observable from outside any editor: the buffer
  exists as soon as the application is up, log calls reach it before any
  editor starts, and the gateway's `:log_message` topic still works.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.Events.LogMessageEvent

  defp unique_tag(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp wait_for_text(buf, tag, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_text(buf, tag, deadline)
  end

  defp do_wait_for_text(buf, tag, deadline) do
    if String.contains?(Buffer.content(buf), tag) do
      :ok
    else
      retry_or_fail(buf, tag, deadline)
    end
  end

  defp retry_or_fail(buf, tag, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("expected #{inspect(tag)} in *Messages*; got:\n#{Buffer.content(buf)}")
    else
      Process.sleep(5)
      do_wait_for_text(buf, tag, deadline)
    end
  end

  describe "singleton lifecycle" do
    test "Minga.Buffer.messages/0 returns a pid in headless mode (no editor running)" do
      refute Process.whereis(MingaEditor)
      pid = Buffer.messages()
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "the buffer is unlisted, persistent and read-only" do
      pid = Buffer.messages()
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

      Minga.Log.info(:editor, tag)

      assert wait_for_text(Buffer.messages(), tag)
    end

    test ":log_message broadcasts append to the shared buffer" do
      tag = unique_tag("event-broadcast")

      Events.broadcast(:log_message, %LogMessageEvent{text: tag, level: :info})

      assert wait_for_text(Buffer.messages(), tag)
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

        assert wait_for_text(Buffer.messages(), tag)
      after
        Events.unsubscribe(:log_message)
      end
    end
  end
end
