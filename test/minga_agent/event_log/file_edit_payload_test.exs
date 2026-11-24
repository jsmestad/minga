defmodule MingaAgent.EventLog.FileEditPayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EventLog.FileEditPayload
  alias MingaAgent.EventLog.Payload

  test "every side round-trips through JSON storage, including the text \"absent\"" do
    for {before_content, after_content} <- [
          {"old", "new"},
          {:absent, "created"},
          {"deleted", :absent},
          {"absent", "absent"},
          {"", :absent}
        ] do
      payload = FileEditPayload.new("lib/a.ex", before_content, after_content, "tc", "edit")
      {:ok, sanitized, _bytes} = Payload.prepare(payload)
      stored = sanitized |> JSON.encode!() |> JSON.decode!()

      assert FileEditPayload.decode_side(stored["before_content"], stored["before_exists"]) ==
               before_content

      assert FileEditPayload.decode_side(stored["after_content"], stored["after_exists"]) ==
               after_content
    end
  end

  test "an absent side stores empty text, so text readers see no file content" do
    payload = FileEditPayload.new("lib/a.ex", :absent, "created", "tc", "write_file")

    assert %{before_content: "", before_exists: false, after_exists: true} = payload
  end

  test "records written before presence flags read the string \"absent\" as a missing file" do
    assert FileEditPayload.decode_side("absent", nil) == :absent
    assert FileEditPayload.decode_side("content", nil) == "content"
    assert FileEditPayload.decode_side(nil, nil) == ""
  end
end
