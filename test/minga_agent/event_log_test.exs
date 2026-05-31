defmodule MingaAgent.EventLogTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EventLog
  alias MingaAgent.EventLog.Store

  @moduletag :tmp_dir

  test "record writes asynchronously and redacts secrets", %{tmp_dir: tmp_dir} do
    name = unique_name("event-log")

    pid =
      start_supervised!(
        {EventLog, name: name, db_dir: tmp_dir, retention_sweep?: false, health_check: :none}
      )

    :ok =
      EventLog.record(
        "session-1",
        :tool_call_started,
        %{
          :api_key => "secret",
          :accessToken => "camel",
          "client-secret" => "hyphen",
          :nested => %{refreshToken: "abc"},
          :pid => self()
        },
        name
      )

    :sys.get_state(pid)

    {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)
    assert {:ok, [record]} = EventLog.events_after(db, "session-1", 0, 10)
    assert record.payload["api_key"] == "[REDACTED]"
    assert record.payload["accessToken"] == "[REDACTED]"
    assert record.payload["client-secret"] == "[REDACTED]"
    assert record.payload["nested"]["refreshToken"] == "[REDACTED]"
    assert record.payload["pid"] == "[PID]"
    :ok = Store.close(db)
  end

  @spec unique_name(String.t()) :: atom()
  defp unique_name(prefix) do
    String.to_atom("#{prefix}-#{System.unique_integer([:positive])}")
  end
end
