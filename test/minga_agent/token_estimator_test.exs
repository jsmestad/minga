defmodule MingaAgent.TokenEstimatorTest do
  use ExUnit.Case, async: true

  alias MingaAgent.TokenEstimator

  doctest MingaAgent.TokenEstimator

  describe "estimate/1" do
    test "empty message list returns 0" do
      assert TokenEstimator.estimate([]) == 0
    end

    test "single system message includes system overhead" do
      messages = [%{role: "system", content: "You are helpful."}]
      result = TokenEstimator.estimate(messages)
      assert result > 10
      assert result < 25
    end

    test "multiple messages accumulate" do
      messages = [
        %{role: "system", content: "You are helpful."},
        %{role: "user", content: "Hello, how are you?"},
        %{role: "assistant", content: "I'm doing well, thank you!"}
      ]

      result = TokenEstimator.estimate(messages)
      assert result > 20
    end

    test "long content produces proportionally more tokens" do
      short = [%{role: "user", content: "Hi"}]
      long = [%{role: "user", content: String.duplicate("word ", 1000)}]

      short_est = TokenEstimator.estimate(short)
      long_est = TokenEstimator.estimate(long)

      assert long_est > short_est * 10
    end

    test "handles list-style content parts" do
      messages = [
        %{role: "user", content: [%{text: "Hello "}, %{text: "world"}]}
      ]

      result = TokenEstimator.estimate(messages)
      assert result > 0
    end

    test "handles messages without content" do
      messages = [%{role: "assistant"}]
      result = TokenEstimator.estimate(messages)
      assert result == 4
    end
  end

  describe "tool call accounting" do
    test "assistant with tool_calls includes function name and arguments" do
      small_args = ~s({"x": 1})
      large_args = String.duplicate("x", 20_000)

      small = [
        %{
          role: :assistant,
          content: [],
          tool_calls: [
            %{function: %{name: "read_file", arguments: small_args}}
          ]
        }
      ]

      large = [
        %{
          role: :assistant,
          content: [],
          tool_calls: [
            %{function: %{name: "read_file", arguments: large_args}}
          ]
        }
      ]

      small_est = TokenEstimator.estimate(small)
      large_est = TokenEstimator.estimate(large)

      assert large_est > small_est * 100,
             "20k-char argument (#{large_est}) should be >100x a tiny argument (#{small_est})"
    end

    test "multiple tool calls accumulate" do
      messages = [
        %{
          role: :assistant,
          content: [],
          tool_calls: [
            %{function: %{name: "read_file", arguments: ~s({"path": "/a.txt"})}},
            %{
              function: %{
                name: "write_file",
                arguments: ~s({"path": "/b.txt", "content": "hello"})
              }
            }
          ]
        }
      ]

      one_call = [
        %{
          role: :assistant,
          content: [],
          tool_calls: [
            %{function: %{name: "read_file", arguments: ~s({"path": "/a.txt"})}}
          ]
        }
      ]

      assert TokenEstimator.estimate(messages) > TokenEstimator.estimate(one_call)
    end

    test "tool result message includes tool_call_id" do
      with_id = [%{role: :tool, content: "result", tool_call_id: "call_abc123def456"}]
      without_id = [%{role: :tool, content: "result"}]

      assert TokenEstimator.estimate(with_id) > TokenEstimator.estimate(without_id)
    end

    test "nil or empty tool_calls do not add tokens" do
      base = [%{role: :assistant, content: "Hello"}]
      with_nil = [%{role: :assistant, content: "Hello", tool_calls: nil}]
      with_empty = [%{role: :assistant, content: "Hello", tool_calls: []}]

      base_est = TokenEstimator.estimate(base)
      assert TokenEstimator.estimate(with_nil) == base_est
      assert TokenEstimator.estimate(with_empty) == base_est
    end
  end

  describe "reasoning details" do
    test "reasoning text is included in the estimate" do
      without = [%{role: :assistant, content: "Answer"}]

      with_reasoning = [
        %{
          role: :assistant,
          content: "Answer",
          reasoning_details: [%{text: String.duplicate("thinking ", 500)}]
        }
      ]

      assert TokenEstimator.estimate(with_reasoning) > TokenEstimator.estimate(without) * 5
    end

    test "nil reasoning_details does not add tokens" do
      base = [%{role: :assistant, content: "Hello"}]
      with_nil = [%{role: :assistant, content: "Hello", reasoning_details: nil}]

      assert TokenEstimator.estimate(with_nil) == TokenEstimator.estimate(base)
    end
  end

  describe "estimate_string/1" do
    test "short string" do
      assert TokenEstimator.estimate_string("Hello") >= 1
    end

    test "empty string returns 1 (minimum)" do
      assert TokenEstimator.estimate_string("") == 1
    end

    test "long string scales linearly" do
      short = TokenEstimator.estimate_string("hello")
      long = TokenEstimator.estimate_string(String.duplicate("hello ", 100))
      assert long > short * 50
    end
  end

  describe "media parts" do
    test "an image counts a fixed per-part cost instead of zero or its encoded bytes" do
      image = ReqLLM.Message.ContentPart.image(:binary.copy(<<0>>, 600_000), "image/png")
      text = ReqLLM.Message.ContentPart.text("look")
      with_image = [%{role: :user, content: [text, image]}]
      text_only = [%{role: :user, content: [text]}]

      assert TokenEstimator.estimate(with_image) - TokenEstimator.estimate(text_only) == 1_600
    end
  end
end
