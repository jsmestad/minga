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

  test "stream reports lazy token enumeration errors to reply_to" do
    client = fn _model, _messages, _opts -> {:ok, stream_response(raising_stream())} end

    {:ok, ref} = AI.stream(@msgs, client: client, reply_to: self())

    assert_receive {:minga_ai, ^ref, {:chunk, "partial"}}, 2_000
    assert_receive {:minga_ai, ^ref, {:error, {:provider_error, "stream blew up"}}}, 2_000
  end

  test "complete maps lazy token enumeration errors to a tagged tuple" do
    client = fn _model, _messages, _opts -> {:ok, stream_response(raising_stream())} end

    assert {:error, {:provider_error, "stream blew up"}} = AI.complete(@msgs, client: client)
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

  @spec raising_stream() :: Enumerable.t()
  defp raising_stream do
    Stream.resource(
      fn -> :first end,
      fn
        :first -> {[ReqLLM.StreamChunk.text("partial")], :raise}
        :raise -> raise "stream blew up"
      end,
      fn _state -> :ok end
    )
  end

  @spec stream_response(Enumerable.t()) :: ReqLLM.StreamResponse.t()
  defp stream_response(stream) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: %{}, finish_reason: :stop}
      end)

    %ReqLLM.StreamResponse{
      stream: stream,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: nil,
      context: ReqLLM.Context.new()
    }
  end
end
