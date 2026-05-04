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
    test "appends entries to Minga.Buffer.messages/0" do
      tag = "logger-handler-shared-#{System.unique_integer([:positive])}"
      event = %{level: :error, msg: {:string, tag}, meta: %{}}

      LoggerHandler.log(event, %{})

      buf = Buffer.messages()
      assert is_pid(buf)
      assert wait_for_text(buf, tag)
    end

    test "preserves level prefix in the formatted text" do
      tag = "logger-handler-level-#{System.unique_integer([:positive])}"

      LoggerHandler.log(%{level: :warning, msg: {:string, tag}, meta: %{}}, %{})

      buf = Buffer.messages()
      assert wait_for_text(buf, "[warning] " <> tag)
    end

    test "formats erlang format strings" do
      tag = "logger-handler-fmt-#{System.unique_integer([:positive])}"

      LoggerHandler.log(
        %{level: :info, msg: {~c"~s pid=~p", [tag, self()]}, meta: %{}},
        %{}
      )

      buf = Buffer.messages()
      assert wait_for_text(buf, tag)
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

  defp wait_for_text(buf, tag, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_text(buf, tag, deadline)
  end

  defp do_wait_for_text(buf, tag, deadline) do
    content = Buffer.content(buf)

    if String.contains?(content, tag) do
      true
    else
      retry_or_fail(buf, tag, deadline, content)
    end
  end

  defp retry_or_fail(buf, tag, deadline, content) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("expected #{inspect(tag)} in *Messages* buffer; got:\n#{content}")
    else
      Process.sleep(10)
      do_wait_for_text(buf, tag, deadline)
    end
  end
end
