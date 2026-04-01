defmodule Minga.LoggerHandlerTest do
  use ExUnit.Case, async: false

  alias Minga.LoggerHandler

  @buffer_table :minga_log_buffer

  setup do
    LoggerHandler.ensure_buffer_table()
    :ets.delete_all_objects(@buffer_table)
    :ok
  end

  describe "ensure_buffer_table/0" do
    test "creates the ETS table" do
      assert :ets.whereis(@buffer_table) != :undefined
    end

    test "is idempotent" do
      assert LoggerHandler.ensure_buffer_table() == :ok
      assert LoggerHandler.ensure_buffer_table() == :ok
      assert :ets.whereis(@buffer_table) != :undefined
    end
  end

  describe "log/2 buffering when Editor is down" do
    test "buffers messages when Editor is not running" do
      # Editor is not started in this test, so whereis returns nil
      refute Process.whereis(MingaEditor)

      event = %{level: :error, msg: {:string, "boom"}, meta: %{}}
      LoggerHandler.log(event, %{})

      entries = :ets.tab2list(@buffer_table)
      assert length(entries) == 1
      [{_key, text, level}] = entries
      assert text == "[error] boom"
      assert level == :error
    end

    test "buffers multiple messages in order" do
      refute Process.whereis(MingaEditor)

      for i <- 1..5 do
        event = %{level: :info, msg: {:string, "msg #{i}"}, meta: %{}}
        LoggerHandler.log(event, %{})
      end

      entries = :ets.tab2list(@buffer_table)
      assert length(entries) == 5

      texts = Enum.map(entries, fn {_key, text, _level} -> text end)

      assert texts == [
               "[info] msg 1",
               "[info] msg 2",
               "[info] msg 3",
               "[info] msg 4",
               "[info] msg 5"
             ]
    end

    test "trims buffer to max size" do
      refute Process.whereis(MingaEditor)

      # Buffer 60 messages (max is 50)
      for i <- 1..60 do
        event = %{level: :info, msg: {:string, "msg #{i}"}, meta: %{}}
        LoggerHandler.log(event, %{})
      end

      size = :ets.info(@buffer_table, :size)
      assert size == 50

      # The oldest messages should have been trimmed, keeping 11..60
      entries = :ets.tab2list(@buffer_table)
      texts = Enum.map(entries, fn {_key, text, _level} -> text end)
      assert hd(texts) == "[info] msg 11"
      assert List.last(texts) == "[info] msg 60"
    end
  end

  describe "flush_buffer/0" do
    test "returns empty list when buffer is empty" do
      assert LoggerHandler.flush_buffer() == []
    end

    test "clears the buffer after flushing" do
      refute Process.whereis(MingaEditor)

      event = %{level: :info, msg: {:string, "test"}, meta: %{}}
      LoggerHandler.log(event, %{})
      assert :ets.info(@buffer_table, :size) == 1

      # flush_buffer sends casts to the Editor, which isn't running.
      # The casts will be dropped (GenServer.cast to a nil pid is a no-op),
      # but the buffer should still be cleared.
      LoggerHandler.flush_buffer()
      assert :ets.info(@buffer_table, :size) == 0
    end

    test "returns the flushed message entries" do
      refute Process.whereis(MingaEditor)

      for i <- 1..3 do
        event = %{level: :warning, msg: {:string, "warn #{i}"}, meta: %{}}
        LoggerHandler.log(event, %{})
      end

      entries = LoggerHandler.flush_buffer()
      assert length(entries) == 3
      assert Enum.all?(entries, fn {text, level} -> is_binary(text) and level == :warning end)
    end
  end

  describe "log/2 message formatting" do
    test "formats string messages" do
      refute Process.whereis(MingaEditor)

      event = %{level: :info, msg: {:string, "hello world"}, meta: %{}}
      LoggerHandler.log(event, %{})

      [{_key, text, _level}] = :ets.tab2list(@buffer_table)
      assert text == "[info] hello world"
    end

    test "formats report messages" do
      refute Process.whereis(MingaEditor)

      event = %{level: :error, msg: {:report, %{reason: :crashed}}, meta: %{}}
      LoggerHandler.log(event, %{})

      [{_key, text, _level}] = :ets.tab2list(@buffer_table)
      assert text =~ "[error]"
      assert text =~ "reason"
    end

    test "formats erlang format string messages" do
      refute Process.whereis(MingaEditor)

      event = %{level: :warning, msg: {~c"process ~p crashed", [self()]}, meta: %{}}
      LoggerHandler.log(event, %{})

      [{_key, text, _level}] = :ets.tab2list(@buffer_table)
      assert text =~ "[warning] process"
      assert text =~ "crashed"
    end

    test "preserves level for warning/error routing" do
      refute Process.whereis(MingaEditor)

      LoggerHandler.log(%{level: :error, msg: {:string, "err"}, meta: %{}}, %{})
      LoggerHandler.log(%{level: :warning, msg: {:string, "warn"}, meta: %{}}, %{})
      LoggerHandler.log(%{level: :info, msg: {:string, "info"}, meta: %{}}, %{})

      entries = :ets.tab2list(@buffer_table)
      levels = Enum.map(entries, fn {_key, _text, level} -> level end)
      assert :error in levels
      assert :warning in levels
      assert :info in levels
    end
  end
end
