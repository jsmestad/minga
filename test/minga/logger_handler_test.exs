defmodule Minga.LoggerHandlerTest do
  use ExUnit.Case, async: false

  alias Minga.Buffer
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

  describe "log/2 routing to the shared *Messages* buffer" do
    test "appends entries to Minga.Log.messages_buffer/0" do
      tag = "logger-handler-shared-#{System.unique_integer([:positive])}"
      event = %{level: :error, msg: {:string, tag}, meta: %{}}

      LoggerHandler.log(event, %{})

      buf = Minga.Log.messages_buffer()
      assert is_pid(buf)
      assert_messages_buffer_contains(tag)
    end

    test "preserves level prefix in the formatted text" do
      tag = "logger-handler-level-#{System.unique_integer([:positive])}"

      LoggerHandler.log(%{level: :warning, msg: {:string, tag}, meta: %{}}, %{})

      assert_messages_buffer_contains("[warning] " <> tag)
    end

    test "formats erlang format strings" do
      tag = "logger-handler-fmt-#{System.unique_integer([:positive])}"

      LoggerHandler.log(
        %{level: :info, msg: {~c"~s pid=~p", [tag, self()]}, meta: %{}},
        %{}
      )

      assert_messages_buffer_contains(tag)
    end
  end

  describe "flush_buffer/0" do
    test "returns and clears entries that the LoggerHandler queued before any subscribers" do
      :ets.insert(@buffer_table, {System.monotonic_time(:nanosecond), "test-flush", :info})
      assert :ets.info(@buffer_table, :size) >= 1

      entries = LoggerHandler.flush_buffer()
      assert Enum.any?(entries, fn {text, level} -> text == "test-flush" and level == :info end)
      assert :ets.info(@buffer_table, :size) == 0
    end

    test "returns empty list when buffer is empty" do
      assert LoggerHandler.flush_buffer() == []
    end
  end

  defp assert_messages_buffer_contains(tag) do
    :sys.get_state(Minga.Log.MessagesBuffer)
    content = Buffer.content(Minga.Log.messages_buffer())

    assert String.contains?(content, tag),
           "expected #{inspect(tag)} in *Messages* buffer; got:\n#{content}"
  end
end
