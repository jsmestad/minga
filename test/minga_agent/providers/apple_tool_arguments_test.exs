defmodule MingaAgent.Providers.AppleToolArgumentsTest do
  # Spawns the real Apple Intelligence helper as an OS process.
  use ExUnit.Case, async: false

  alias MingaAgent.Providers.Apple
  alias ReqLLM.{Context, StreamResponse, Tool}

  @moduletag :apple_inference
  @moduletag timeout: 180_000

  setup_all do
    case Apple.availability() do
      {:ok, _context} -> :ok
      {:error, reason} -> flunk("MINGA_APPLE_INFERENCE=1 needs a ready Apple model: #{reason}")
    end
  end

  test "a call that breaks a length rule Apple cannot guide is published for Minga to validate" do
    # Apple guided generation enforces types but not string length, so the model can
    # produce "ABCDEFGHIJ" here. The helper must publish that call rather than end the turn.
    tool =
      Tool.new!(
        name: "record_code",
        description: "Records a code exactly as the user wrote it.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{"code" => %{"type" => "string", "maxLength" => 3}},
          "required" => ["code"]
        },
        callback: fn _args -> {:ok, "unused"} end
      )

    model = LLMDB.Model.new!(%{provider: :apple, id: "system"})

    messages = [
      Context.system("Always call record_code with the user's code copied exactly."),
      Context.user("Record the code ABCDEFGHIJ.")
    ]

    assert {:ok, response} =
             Apple.stream_text(model, messages,
               tools: [tool],
               max_tokens: 256,
               apple_admission: fn _digest, _tokens, _prefix, _cap, _context -> :ok end
             )

    # The old helper ended the stream with "Invalid arguments for Apple tool record_code".
    assert [%{name: "record_code", arguments: %{"code" => "ABCDEFGHIJ"}}] =
             StreamResponse.extract_tool_calls(response)
  end
end
