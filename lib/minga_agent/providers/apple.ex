defmodule MingaAgent.Providers.Apple do
  @moduledoc "Credential-free ReqLLM adapter for the bundled Apple Intelligence inference helper."

  use ReqLLM.Provider, id: :apple, default_base_url: ""

  alias ReqLLM.{Context, StreamChunk, StreamResponse, Tool, ToolCall}
  alias ReqLLM.Provider.InProcessStream

  @helper "minga-apple-inference"
  @probe_timeout 2_000
  @inference_timeout 120_000
  @max_frame 131_072
  @unavailable %{
    "unsupported" => :unsupported,
    "disabled" => :disabled,
    "model_not_ready" => :model_not_ready,
    "unsupported_locale" => :unsupported_locale,
    "probe_failed" => :probe_failed
  }

  @type unavailable ::
          :unsupported
          | :helper_missing
          | :disabled
          | :model_not_ready
          | :unsupported_locale
          | :probe_failed
  @type stream_state :: reference() | :done

  @doc "Probes the bundled helper without generating text or reading any credentials."
  @spec availability() :: {:ok, pos_integer()} | {:error, unavailable()}
  def availability do
    with {:ok, path} <- helper_path(),
         {:ok, %{"status" => status} = response} <- availability_response(path) do
      case response do
        %{"status" => "ready", "context" => context} when is_integer(context) and context > 0 ->
          {:ok, context}

        _ ->
          {:error, Map.get(@unavailable, status, :probe_failed)}
      end
    else
      {:error, reason} when reason in [:unsupported, :helper_missing] -> {:error, reason}
      _failure -> {:error, :probe_failed}
    end
  end

  @doc "Streams a single Apple inference using ReqLLM's canonical stream processing."
  @spec stream_text(LLMDB.Model.t(), [ReqLLM.Message.t()], keyword()) ::
          {:ok, StreamResponse.t()} | {:error, term()}
  def stream_text(%LLMDB.Model{provider: :apple} = model, messages, opts) do
    opts = Keyword.put(opts, :receive_timeout, @inference_timeout + @probe_timeout)
    ReqLLM.Streaming.start_stream(__MODULE__, model, Context.new(messages), opts)
  end

  @impl true
  @spec stream_transport(LLMDB.Model.t(), keyword()) :: :in_process
  def stream_transport(_model, _opts), do: :in_process

  @impl true
  @spec attach_in_process_stream(LLMDB.Model.t(), Context.t(), keyword()) ::
          {:ok, InProcessStream.t()} | {:error, term()}
  def attach_in_process_stream(_model, %Context{messages: messages}, opts) do
    with {:ok, path} <- helper_path(),
         {:ok, messages} <- project_messages(messages, []),
         {:ok, tools} <- project_tools(Keyword.get(opts, :tools, []), []),
         {:ok, payload} <- encode_request(messages, tools, Keyword.get(opts, :max_tokens, 512)) do
      owner = self()
      worker = spawn(fn -> await_consumer(owner, path, payload) end)

      stream =
        Stream.resource(
          fn ->
            ref = Process.monitor(worker)
            send(worker, {:consume, self()})
            ref
          end,
          &next_chunk(worker, &1),
          &close_stream(worker, &1)
        )

      {:ok, InProcessStream.new(stream, cancel: fn -> send(worker, :cancel) end)}
    end
  end

  @spec helper_path() :: {:ok, String.t()} | {:error, :unsupported | :helper_missing}
  defp helper_path do
    with {:unix, :darwin} <- :os.type(),
         true <-
           String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64-"),
         priv when is_list(priv) <- :code.priv_dir(:minga) do
      path = Path.join(List.to_string(priv), @helper)
      if File.regular?(path), do: {:ok, path}, else: {:error, :helper_missing}
    else
      _unsupported -> {:error, :unsupported}
    end
  end

  @spec availability_response(String.t()) :: {:ok, map()} | {:error, term()}
  defp availability_response(path) do
    with {:ok, port} <- open_helper(path) do
      try do
        if Port.command(port, "{\"op\":\"availability\"}\n") do
          receive do
            {^port, {:data, {:eol, line}}} -> decode_frame(line)
            {^port, {:data, {:noeol, _line}}} -> {:error, :oversized_apple_frame}
            {^port, {:exit_status, status}} -> {:error, {:apple_helper_exit, status}}
          after
            @probe_timeout -> {:error, :apple_probe_timeout}
          end
        else
          {:error, :apple_helper_unavailable}
        end
      after
        close_helper(port)
      end
    end
  end

  @spec project_messages([ReqLLM.Message.t()], [map()]) :: {:ok, [map()]} | {:error, term()}
  defp project_messages([], acc), do: {:ok, Enum.reverse(acc)}

  defp project_messages([%{role: role} = message | rest], acc)
       when role in [:system, :user, :assistant, :tool] do
    with {:ok, text} <- message_text(message.content || [], []),
         {:ok, calls} <- project_calls(message.tool_calls || [], []) do
      projected = %{role: role, text: text, tool_call_id: message.tool_call_id, tool_calls: calls}

      projected =
        if role == :tool,
          do: Map.put(projected, :is_error, message.metadata[:is_error] == true),
          else: projected

      project_messages(rest, [projected | acc])
    end
  end

  defp project_messages(_messages, _acc), do: {:error, :unsupported_apple_message}

  @spec message_text([ReqLLM.Message.ContentPart.t()], [String.t()]) ::
          {:ok, String.t()} | {:error, :unsupported_apple_content}
  defp message_text([], acc), do: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

  defp message_text([%{type: :text, text: text} | rest], acc) when is_binary(text),
    do: message_text(rest, [text | acc])

  defp message_text(_content, _acc), do: {:error, :unsupported_apple_content}

  @spec project_calls([ToolCall.t()], [map()]) ::
          {:ok, [map()]} | {:error, :invalid_apple_tool_call}
  defp project_calls([], acc), do: {:ok, Enum.reverse(acc)}

  defp project_calls([%{id: id, function: %{name: name, arguments: arguments}} | rest], acc)
       when is_binary(id) and is_binary(name) and is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, args} when is_map(args) ->
        project_calls(rest, [%{id: id, name: name, arguments: args} | acc])

      _invalid ->
        {:error, :invalid_apple_tool_call}
    end
  end

  defp project_calls(_calls, _acc), do: {:error, :invalid_apple_tool_call}

  @spec project_tools([Tool.t()], [map()]) :: {:ok, [map()]} | {:error, :unsupported_apple_tool}
  defp project_tools([], acc), do: {:ok, Enum.reverse(acc)}

  defp project_tools([%Tool{name: name, description: description} = tool | rest], acc) do
    case Tool.to_json_schema(tool) do
      %{"function" => %{"parameters" => schema}} when is_map(schema) ->
        project_tools(rest, [%{name: name, description: description, schema: schema} | acc])

      _unsupported ->
        {:error, :unsupported_apple_tool}
    end
  end

  defp project_tools(_tools, _acc), do: {:error, :unsupported_apple_tool}

  @spec encode_request([map()], [map()], term()) :: {:ok, iodata()} | {:error, term()}
  defp encode_request(messages, tools, budget) when is_integer(budget) and budget > 0 do
    data =
      JSON.encode!(%{op: "infer", messages: messages, tools: tools, max_output_tokens: budget})

    if byte_size(data) < @max_frame,
      do: {:ok, [data, "\n"]},
      else: {:error, :oversized_apple_request}
  end

  defp encode_request(_messages, _tools, _budget), do: {:error, :invalid_apple_output_budget}

  @spec open_helper(String.t()) :: {:ok, port()} | {:error, term()}
  defp open_helper(path) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :use_stdio,
        :exit_status,
        {:line, @max_frame}
      ])

    {:ok, port}
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:apple_helper_start, error}}
  end

  @spec close_helper(port()) :: :ok
  defp close_helper(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec await_consumer(pid(), String.t(), iodata()) :: :ok
  defp await_consumer(owner, path, payload) do
    owner_ref = Process.monitor(owner)

    receive do
      {:consume, consumer} ->
        consumer_ref = Process.monitor(consumer)
        run_helper(path, payload, consumer, owner_ref, consumer_ref)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      :cancel ->
        :ok
    after
      @probe_timeout -> :ok
    end
  end

  @spec run_helper(String.t(), iodata(), pid(), reference(), reference()) :: :ok
  defp run_helper(path, payload, consumer, owner_ref, consumer_ref) do
    case open_helper(path) do
      {:ok, port} ->
        try do
          if Port.command(port, payload) do
            deadline = System.monotonic_time(:millisecond) + @inference_timeout
            forward_frames(port, consumer, owner_ref, consumer_ref, deadline)
          else
            publish(consumer, [{:error, :apple_helper_unavailable}])
          end
        after
          close_helper(port)
        end

      {:error, reason} ->
        publish(consumer, [{:error, reason}])
    end
  end

  @spec forward_frames(port(), pid(), reference(), reference(), integer()) :: :ok
  defp forward_frames(port, consumer, owner_ref, consumer_ref, deadline) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case chunks(line) do
          {:delta, chunk} ->
            send(consumer, {self(), :delta, chunk})
            forward_frames(port, consumer, owner_ref, consumer_ref, deadline)

          {:terminal, chunks} ->
            publish(consumer, chunks)
        end

      {^port, {:data, {:noeol, _line}}} ->
        publish(consumer, [{:error, :oversized_apple_frame}])

      {^port, {:exit_status, status}} ->
        publish(consumer, [{:error, {:apple_helper_exit, status}}])

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        :ok

      {:DOWN, ^consumer_ref, :process, _pid, _reason} ->
        :ok

      :cancel ->
        :ok
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        publish(consumer, [{:error, :apple_inference_timeout}])
    end
  end

  @spec chunks(binary()) ::
          {:delta, StreamChunk.t()} | {:terminal, [StreamChunk.t() | {:error, term()}]}
  defp chunks(line) do
    case decode_frame(line) do
      {:ok, %{"delta" => delta}} when is_binary(delta) ->
        {:delta, StreamChunk.text(delta)}

      {:ok, %{"finish" => "stop"}} ->
        {:terminal, [StreamChunk.meta(%{finish_reason: :stop})]}

      {:ok, %{"calls" => [_ | _] = calls}} ->
        {:terminal, tool_chunks(calls, 0, %{}, [])}

      {:ok, %{"error" => reason}} when is_binary(reason) ->
        {:terminal, [{:error, {:apple_inference, reason}}]}

      _invalid ->
        {:terminal, [{:error, :invalid_apple_frame}]}
    end
  end

  @spec tool_chunks([map()], non_neg_integer(), %{optional(String.t()) => true}, [StreamChunk.t()]) ::
          [StreamChunk.t() | {:error, :invalid_apple_tool_group}]
  defp tool_chunks([], _index, _ids, acc),
    do: Enum.reverse(acc, [StreamChunk.meta(%{finish_reason: :tool_calls})])

  defp tool_chunks([%{"id" => id, "name" => name, "arguments" => args} | rest], index, ids, acc)
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(args) do
    if Map.has_key?(ids, id) do
      [{:error, :invalid_apple_tool_group}]
    else
      chunk = StreamChunk.tool_call(name, args, %{id: id, index: index})
      tool_chunks(rest, index + 1, Map.put(ids, id, true), [chunk | acc])
    end
  end

  defp tool_chunks(_calls, _index, _ids, _acc), do: [{:error, :invalid_apple_tool_group}]

  @spec decode_frame(binary()) :: {:ok, map()} | {:error, :invalid_apple_frame}
  defp decode_frame(line) do
    case JSON.decode(line) do
      {:ok, frame} when is_map(frame) -> {:ok, frame}
      _invalid -> {:error, :invalid_apple_frame}
    end
  end

  @spec publish(pid(), [StreamChunk.t() | {:error, term()}]) :: :ok
  defp publish(consumer, chunks) do
    send(consumer, {self(), :terminal, chunks})
    :ok
  end

  @spec next_chunk(pid(), stream_state()) ::
          {[StreamChunk.t() | {:error, term()}], stream_state()} | {:halt, :done}
  defp next_chunk(_worker, :done), do: {:halt, :done}

  defp next_chunk(worker, ref) do
    receive do
      {^worker, :delta, chunk} ->
        {[chunk], ref}

      {^worker, :terminal, chunks} ->
        Process.demonitor(ref, [:flush])
        {chunks, :done}

      {:DOWN, ^ref, :process, ^worker, reason} ->
        {[{:error, {:apple_helper_down, reason}}], :done}
    after
      @inference_timeout ->
        close_stream(worker, ref)
        {[{:error, :apple_inference_timeout}], :done}
    end
  end

  @spec close_stream(pid(), stream_state()) :: :ok
  defp close_stream(_worker, :done), do: :ok

  defp close_stream(worker, ref) do
    Process.demonitor(ref, [:flush])
    send(worker, :cancel)
    :ok
  end
end
