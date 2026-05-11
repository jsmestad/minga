defmodule MingaAgent.Hooks.UserPromptSubmitPayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.UserPromptSubmitPayload

  test "new/2 builds a payload from a string prompt" do
    payload = UserPromptSubmitPayload.new("sess_1", "hello world")

    assert payload.event == "UserPromptSubmit"
    assert payload.session_id == "sess_1"
    assert payload.prompt == "hello world"
  end

  test "new/2 extracts text from content parts list" do
    parts = [
      %{type: :text, text: "first part"},
      %{type: :image, url: "http://example.com/img.png"},
      %{type: :text, text: "second part"}
    ]

    payload = UserPromptSubmitPayload.new("sess_2", parts)
    assert payload.prompt == "first part\nsecond part"
  end

  test "new/2 handles plain string list entries" do
    parts = ["hello", "world"]
    payload = UserPromptSubmitPayload.new("sess_3", parts)
    assert payload.prompt == "hello\nworld"
  end

  test "to_map/1 produces the expected JSON shape" do
    payload = UserPromptSubmitPayload.new("sess_4", "test prompt")
    map = UserPromptSubmitPayload.to_map(payload)

    assert map == %{
             "event" => "UserPromptSubmit",
             "session_id" => "sess_4",
             "prompt" => "test prompt"
           }
  end

  test "payload is Jason-encodable" do
    payload = UserPromptSubmitPayload.new("sess_5", "encode me")
    assert {:ok, json} = Jason.encode(payload)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["event"] == "UserPromptSubmit"
    assert decoded["prompt"] == "encode me"
  end
end
