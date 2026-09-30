# Run with `MIX_ENV=prod mix run bench/agent_continuation_bench.exs`.
# The legacy path rebuilds ReqLLM messages from the same display fixture; it is
# a cost baseline, not a fidelity-equivalent implementation.

defmodule AgentContinuationBench do
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.ContinuationCodec
  alias MingaAgent.Session.Outcome
  alias MingaAgent.SessionStore
  alias MingaAgent.ToolCall
  alias ReqLLM.Context
  alias ReqLLM.Message

  @samples 30
  @large_output String.duplicate("tool output line\n", 4_096)

  def run do
    root =
      Path.join(
        System.tmp_dir!(),
        "minga-continuation-bench-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    try do
      for count <- [10, 1_000, 10_000] do
        fixture = fixture(count)
        run_size(root, count, fixture)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp run_size(root, count, {messages, display}) do
    {:ok, continuation} =
      Continuation.restore(
        messages,
        1,
        1,
        [%{transcript_id: count, message_count: length(messages), revision: 1}],
        %{},
        :lossless
      )

    encoded = ContinuationCodec.encode(continuation)

    new_append =
      measure(fn index ->
        Continuation.begin_request(continuation, "append-#{index}", 2, "next prompt")
      end)

    legacy_append =
      measure(fn _index ->
        Enum.map(display, &rebuild_message/1) ++ [Context.user("next prompt")]
      end)

    new_commit =
      measure(fn index ->
        {:ok, request, active} =
          Continuation.begin_request(continuation, "commit-#{index}", 2, "next prompt")

        outcome = Outcome.new(request, request.messages ++ [Context.assistant("next answer")])

        {:ok, completed} = Continuation.complete(active, outcome, count + 1)
        completed |> ContinuationCodec.encode() |> JSON.encode!()
      end)

    {:ok, stage_request, stage_active} =
      Continuation.begin_request(continuation, "stages", 2, "next prompt")

    stage_outcome = Outcome.new(stage_request, stage_request.messages ++ [Context.assistant("next answer")])
    {:ok, stage_completed} = Continuation.complete(stage_active, stage_outcome, count + 1)

    validate_messages = measure(fn _index -> Continuation.validate_messages(stage_outcome.messages) end)

    validate_prefix =
      measure(fn _index ->
        Enum.take(stage_outcome.messages, length(stage_request.messages)) == stage_request.messages
      end)

    complete_only =
      measure(fn _index ->
        Continuation.complete(stage_active, stage_outcome, count + 1)
      end)

    codec_only = measure(fn _index -> ContinuationCodec.encode(stage_completed) end)

    json_only =
      measure(fn _index -> stage_completed |> ContinuationCodec.encode() |> JSON.encode!() end)

    legacy_commit =
      measure(fn _index ->
        legacy_json(display ++ [{:user, "next prompt"}, {:assistant, "next answer"}])
      end)

    new_restore = measure(fn _index -> ContinuationCodec.decode(encoded) end)
    legacy_encoded = legacy_json(display)
    legacy_restore = measure(fn _index -> decode_legacy_display(legacy_encoded) end)

    store_data = %{
      id: "warm-#{count}",
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      title: "Continuation benchmark",
      model_name: "benchmark:model",
      provider_name: "benchmark",
      messages: display,
      continuation: continuation,
      usage: %MingaAgent.TurnUsage{}
    }

    :ok = SessionStore.save(store_data, root)
    cold_store_save = measure_store(root, store_data, :cold_save)
    warm_store_save = measure_store(root, store_data, :warm_save)
    warm_store_load = measure_store(root, store_data, :warm_load)
    concurrent_store = concurrent_stores(root, store_data)
    display_bytes = byte_size(legacy_json(display))
    continuation_payload_bytes = byte_size(JSON.encode!(encoded))

    stored_bytes =
      Path.join(SessionStore.sessions_dir(root), "#{store_data.id}.json")
      |> File.stat!()
      |> Map.fetch!(:size)

    legacy_retained = :erlang.external_size(display)
    continuation_retained = :erlang.external_size(continuation)

    IO.puts("messages=#{count} large_tool_output_bytes=#{byte_size(@large_output)}")
    IO.puts("  append_us baseline=#{format(legacy_append)} continuation=#{format(new_append)}")
    IO.puts("  boundary_us baseline=#{format(legacy_commit)} continuation=#{format(new_commit)}")
    IO.puts("  restore_us baseline=#{format(legacy_restore)} continuation=#{format(new_restore)}")

    IO.puts(
      "  snapshot_bytes baseline=#{display_bytes} continuation=#{stored_bytes} continuation_payload=#{continuation_payload_bytes}"
    )

    IO.puts("  retained_bytes baseline=#{legacy_retained} continuation=#{continuation_retained}")

    IO.puts(
      "  store_new_file_save_us=#{format(cold_store_save)} reused_file_save_us=#{format(warm_store_save)} reused_file_load_us=#{format(warm_store_load)}"
    )

    IO.puts(
      "  boundary_stages_us validate=#{format(validate_messages)} prefix=#{format(validate_prefix)} complete=#{format(complete_only)} codec=#{format(codec_only)} json=#{format(json_only)}"
    )
    IO.puts("  concurrent_two_session_save_us=#{format(concurrent_store)}")
  end

  defp fixture(count) do
    messages =
      for index <- 1..count do
        cond do
          index == div(count, 2) ->
            Context.tool_result_message("read_file", "large-output", @large_output, %{
              is_error: false
            })

          rem(index, 2) == 0 ->
            Context.assistant("assistant message #{index}")

          true ->
            Context.user("user message #{index}")
        end
      end

    display =
      Enum.map(messages, fn
        %Message{role: :user, content: content} ->
          {:user, text(content)}

        %Message{role: :assistant, content: content} ->
          {:assistant, text(content)}

        %Message{role: :tool, tool_call_id: id, content: content} ->
          tool_call = ToolCall.new(id, "read_file") |> ToolCall.complete(text(content))
          {:tool_call, tool_call}

        %Message{role: :system, content: content} ->
          {:system, text(content), :info}
      end)

    {messages, display}
  end

  defp rebuild_message({:user, text}), do: Context.user(text)
  defp rebuild_message({:assistant, text}), do: Context.assistant(text)
  defp rebuild_message({:system, text, _level}), do: Context.system(text)

  defp rebuild_message({:tool_call, %ToolCall{id: id, name: name, result: result}}),
    do: Context.tool_result_message(name, id, result, %{is_error: false})

  defp legacy_json(display) do
    JSON.encode!(%{
      "messages" => Enum.map(display, &encode_display_message/1)
    })
  end

  defp encode_display_message({:user, text}), do: %{"role" => "user", "text" => text}
  defp encode_display_message({:assistant, text}), do: %{"role" => "assistant", "text" => text}

  defp encode_display_message({:system, text, level}),
    do: %{"role" => "system", "text" => text, "level" => Atom.to_string(level)}

  defp encode_display_message({:tool_call, %ToolCall{} = tool_call}) do
    %{
      "role" => "tool",
      "id" => tool_call.id,
      "name" => tool_call.name,
      "result" => tool_call.result
    }
  end

  defp decode_legacy_display(json) do
    json
    |> JSON.decode!()
    |> Map.fetch!("messages")
    |> Enum.map(fn
      %{"role" => "user", "text" => text} ->
        Context.user(text)

      %{"role" => "assistant", "text" => text} ->
        Context.assistant(text)

      %{"role" => "system", "text" => text} ->
        Context.system(text)

      %{"role" => "tool", "id" => id, "name" => name, "result" => result} ->
        Context.tool_result_message(name, id, result, %{is_error: false})
    end)
  end

  defp measure(fun) do
    1..@samples
    |> Enum.map(fn index -> timed(fn -> fun.(index) end) end)
    |> percentiles()
  end

  defp measure_store(root, data, temperature) do
    1..@samples
    |> Enum.map(fn index ->
      id = if temperature == :cold_save, do: "cold-#{data.id}-#{index}", else: data.id

      timed(fn ->
        case temperature do
          :cold_save -> :ok = SessionStore.save(%{data | id: id}, root)
          :warm_save -> :ok = SessionStore.save(data, root)
          :warm_load -> {:ok, _loaded} = SessionStore.load(id, root)
        end
      end)
    end)
    |> percentiles()
  end

  defp concurrent_stores(root, data) do
    1..@samples
    |> Enum.map(fn round ->
      timed(fn ->
        1..2
        |> Enum.map(fn session ->
          Task.async(fn ->
            id = "concurrent-#{round}-#{session}"
            :ok = SessionStore.save(%{data | id: id}, root)
          end)
        end)
        |> Enum.each(&Task.await(&1, :infinity))
      end)
    end)
    |> percentiles()
  end

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    _result = fun.()
    System.monotonic_time(:microsecond) - started
  end

  defp percentiles(samples) do
    sorted = Enum.sort(samples)
    %{p50: percentile(sorted, 50), p95: percentile(sorted, 95), p99: percentile(sorted, 99)}
  end

  defp percentile(sorted, percentile) do
    index = min(div(length(sorted) * percentile + 99, 100), length(sorted)) - 1
    Enum.at(sorted, index)
  end

  defp format(%{p50: p50, p95: p95, p99: p99}), do: "p50=#{p50},p95=#{p95},p99=#{p99}"

  defp text(content) when is_binary(content), do: content
  defp text(content) when is_list(content), do: Enum.map_join(content, & &1.text)
end

AgentContinuationBench.run()
