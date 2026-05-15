defmodule Minga.Log.MessagesBufferTest do
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
end
