defmodule Minga.Extension.AITest do
  use ExUnit.Case, async: true

  alias Minga.Extension.AI

  @msgs [%{role: "user", content: "hi"}]

  test "complete maps a provider error to a tagged tuple" do
    client = fn _model, _messages, _opts -> {:error, :boom} end
    assert {:error, {:provider_error, :boom}} = AI.complete(@msgs, client: client)
  end

  test "stream delivers a tagged provider error to reply_to" do
    client = fn _model, _messages, _opts -> {:error, :boom} end
    {:ok, ref} = AI.stream(@msgs, client: client, reply_to: self())
    assert_receive {:minga_ai, ^ref, {:error, {:provider_error, :boom}}}, 2000
  end

  test "system prompt is prepended ahead of the messages" do
    test_pid = self()

    client = fn _model, messages, _opts ->
      send(test_pid, {:captured, messages})
      {:error, :stop}
    end

    AI.complete(@msgs, client: client, system: "You are terse.")

    assert_receive {:captured,
                    [
                      %{role: "system", content: "You are terse."},
                      %{role: "user", content: "hi"}
                    ]}
  end
end
