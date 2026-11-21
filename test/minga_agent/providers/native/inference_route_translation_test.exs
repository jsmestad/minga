defmodule MingaAgent.Providers.Native.InferenceRouteTranslationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaAgent.InferenceRoute.{ConversationRef, Credential, Message, Request, Response}
  alias MingaAgent.InferenceRoute.{ToolCall, ToolDeclaration, Usage}
  alias MingaAgent.Providers.Native.{InferenceRouteRequest, InferenceRouteResponse}
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias MingaAgent.Test.FixtureInferenceRoute
  alias ReqLLM.Message.ContentPart

  defp conversation(purpose) do
    {:ok, ref} =
      ConversationRef.new(
        session_id: "session",
        owner: self(),
        epoch_id: "epoch",
        conversation_revision: 2,
        request_id: "request",
        purpose: purpose
      )

    ref
  end

  defp opts(purpose \\ :turn, extra \\ []) do
    Keyword.merge(
      [minga_conversation: conversation(purpose), max_tokens: 512, minga_reasoning: "low"],
      extra
    )
  end

  defp build(messages, opts \\ opts()),
    do: InferenceRouteRequest.build(FixtureInferenceRoute.model(), messages, opts)

  defp req_message(role, content, fields \\ []),
    do: struct!(ReqLLM.Message, Keyword.merge([role: role, content: content], fields))

  describe "native messages to a route request" do
    test "each supported part maps to one Minga part" do
      call = ReqLLM.ToolCall.new("tc1", "read_file", ~s({"path":"a.txt"}))

      cases = [
        {req_message(:user, [ContentPart.text("hi")]),
         %Message{role: :user, content: [{:text, "hi"}]}},
        {req_message(:user, [ContentPart.image(<<1, 2>>, "image/png")]),
         %Message{role: :user, content: [{:image, "image/png", <<1, 2>>}]}},
        {req_message(:assistant, [ContentPart.thinking("why", %{signature: "sig"})]),
         %Message{role: :assistant, content: [{:thinking, "why", "sig"}]}},
        {req_message(:assistant, [ContentPart.thinking("why")]),
         %Message{role: :assistant, content: [{:thinking, "why", nil}]}},
        {req_message(:assistant, [ContentPart.text("calling")], tool_calls: [call]),
         %Message{
           role: :assistant,
           content: [
             {:text, "calling"},
             {:tool_call,
              %ToolCall{id: "tc1", name: "read_file", arguments: %{"path" => "a.txt"}}}
           ]
         }},
        {req_message(:tool, [ContentPart.text("denied")],
           tool_call_id: "tc1",
           metadata: %{is_error: true}
         ), %Message{role: :tool, content: [{:tool_result, "tc1", [{:text, "denied"}], true}]}},
        {req_message(:tool, [ContentPart.text("ok"), ContentPart.image(<<3>>, "image/jpeg")],
           tool_call_id: "tc2"
         ),
         %Message{
           role: :tool,
           content: [{:tool_result, "tc2", [{:text, "ok"}, {:image, "image/jpeg", <<3>>}], false}]
         }}
      ]

      for {native, expected} <- cases do
        assert {:ok, %Request{messages: [^expected]}} = build([native])
      end
    end

    test "system messages become the system prompt and never a message" do
      system = [
        req_message(:system, [ContentPart.text("one")]),
        req_message(:system, [ContentPart.text("two")])
      ]

      assert {:ok, %Request{system: "one\n\ntwo", messages: []}} = build(system)
      assert {:ok, %Request{system: nil}} = build([req_message(:user, [ContentPart.text("x")])])
    end

    test "content a route cannot receive fails the request instead of being dropped" do
      cases = [
        {ContentPart.image_url("https://example.com/a.png"), :image_url},
        {ContentPart.video_url("https://example.com/a.mp4"), :video_url},
        {%ContentPart{type: :file, data: "pdf", media_type: "application/pdf"}, :file},
        {%ContentPart{type: :provider_block, data: %{}}, :provider_block}
      ]

      for {part, type} <- cases do
        assert {:error, {:inference_route_unsupported_content, ^type}} =
                 build([req_message(:user, [part])])
      end

      assert {:error, {:inference_route_unsupported_content, :thinking}} =
               build([req_message(:tool, [ContentPart.thinking("x")], tool_call_id: "t")])
    end

    test "tools, options, and credential come from the prepared options" do
      tool =
        ReqLLM.Tool.new!(
          name: "fixture_echo",
          description: "Echo",
          parameter_schema: [value: [type: :string, required: true]],
          callback: fn _ -> {:ok, "x"} end
        )

      credential = Credential.new(%{"TOKEN" => "secret"})
      turn = opts(:turn, tools: [tool], route_credential: credential)

      assert {:ok, request} = build([], turn)

      assert [%ToolDeclaration{name: "fixture_echo", description: "Echo", input_schema: schema}] =
               request.tools

      assert schema["type"] == "object"
      assert Enum.all?(Map.keys(schema), &is_binary/1)
      assert request.options.max_output_tokens == 512
      assert request.options.reasoning == "low"
      assert request.credential == credential

      assert {:ok, %Request{tools: []}} = build([], opts(:summary, tools: [tool]))
      assert {:error, :inference_route_missing_conversation} = build([], max_tokens: 1)
    end
  end

  describe "route responses to the native stream" do
    defp process(events) do
      model = elem(ReqLLM.model(%{provider: :contributed, id: "m", model: "m"}), 1)
      response = %Response{events: events, cancel: fn -> :ok end}
      {:ok, stream} = InferenceRouteResponse.to_stream_response(response, model, [])
      ReqLLMAdapter.process_stream(stream)
    end

    defp text_of(message),
      do: for(%ContentPart{type: :text, text: text} <- message.content, into: "", do: text)

    test "each event kind reaches the native turn result" do
      call = %ToolCall{id: "tc1", name: "echo", arguments: %{"a" => 1}}

      assert {:ok, result} =
               process([
                 {:thinking, "hmm"},
                 {:text, "Hello"},
                 {:tool_call, call},
                 {:usage, %Usage{input_tokens: 3, output_tokens: 4, cache_read_tokens: 1}},
                 {:finish, :tool_calls}
               ])

      assert text_of(result.message) == "Hello"

      assert Enum.any?(
               result.message.content,
               &match?(%ContentPart{type: :thinking, text: "hmm"}, &1)
             )

      assert [%{id: "tc1", name: "echo", arguments: %{"a" => 1}}] = result.tool_calls
      assert %{input_tokens: 3, output_tokens: 4, cache_read_input_tokens: 1} = result.usage
    end

    test "finish reasons map onto the native outcome" do
      assert {:ok, _result} = process([{:text, "x"}, {:finish, :stop}])
      assert {:ok, _result} = process([{:text, "x"}])

      for reason <- [:length, :refusal] do
        assert {:error, {:incomplete_response, _finish}, "x"} =
                 process([{:text, "x"}, {:finish, reason}])
      end

      assert {:error, :rate_limited, "x"} =
               process([{:text, "x"}, {:finish, {:error, :rate_limited}}])
    end

    test "an invalid event ends the stream as a route failure" do
      for invalid <- [{:bogus, 1}, {:text, 42}, {:usage, %Usage{input_tokens: -1}}, nil] do
        assert {:error, {:inference_route_invalid_event, _summary}, "partial"} =
                 process([{:text, "partial"}, invalid, {:text, "never"}])
      end

      model = elem(ReqLLM.model(%{provider: :contributed, id: "m", model: "m"}), 1)

      assert {:error, {:inference_route_invalid_response, _summary}} =
               InferenceRouteResponse.to_stream_response(:not_a_response, model, [])
    end

    property "valid event sequences keep their text and tool calls" do
      check all(
              events <-
                list_of(
                  one_of([
                    map(string(:printable, min_length: 1), &{:text, &1}),
                    map(string(:printable, min_length: 1), &{:thinking, &1}),
                    map(
                      {string(:alphanumeric, min_length: 1), integer()},
                      fn {name, value} ->
                        {:tool_call,
                         %ToolCall{
                           id: "id-#{name}-#{value}",
                           name: name,
                           arguments: %{"v" => value}
                         }}
                      end
                    )
                  ]),
                  max_length: 12
                ),
              usage <- integer(0..1000),
              max_runs: 50
            ) do
        events = Enum.uniq_by(events, &event_identity/1)
        input = events ++ [{:usage, %Usage{input_tokens: usage}}, {:finish, :stop}]

        assert {:ok, result} = process(input)
        assert text_of(result.message) == for({:text, text} <- events, into: "", do: text)

        assert Enum.map(result.tool_calls, &{&1.id, &1.name, &1.arguments}) ==
                 for({:tool_call, call} <- events, do: {call.id, call.name, call.arguments})

        assert result.usage.input_tokens == usage
      end
    end

    defp event_identity({:tool_call, call}), do: {:tool_call, call.id}
    defp event_identity(event), do: {make_ref(), event}
  end
end
