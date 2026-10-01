defmodule Minga.Smoke.NativeRetainedImage do
  @moduledoc false

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Config
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.Event
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection
  alias MingaAgent.ProviderPacks.Native, as: NativePack
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session.Request
  alias MingaAgent.Tools
  alias ReqLLM.Context

  @timeout 15_000

  @spec run() :: :ok
  def run do
    {:ok, _apps} = Application.ensure_all_started(:req_llm)

    root =
      Path.join(
        System.tmp_dir!(),
        "minga-native-retained-image-#{System.unique_integer([:positive])}"
      )

    project = Path.join(root, "project")
    File.mkdir_p!(project)
    image = valid_png()
    ensure!(byte_size(image) > 64 * 1_024, "PNG fixture did not cross one fetch page")
    File.write!(Path.join(project, "retained.png"), image)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()
    server = spawn_link(fn -> serve_requests(listener, parent, image, 1) end)
    {:ok, quota} = ArtifactQuota.start_link(root: Path.join(root, "artifacts"))

    {:ok, store} =
      ArtifactStore.start_link(
        root: Path.join(root, "artifacts"),
        quota: quota,
        session_id: "native-retained-image-smoke"
      )

    subscriber = spawn_link(fn -> subscriber_loop(parent, store) end)
    config = smoke_config(port)
    key = "retained-image-loopback-only"
    previous_key = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", key)
    snapshot = MingaAgent.Credentials.snapshot(oauth_identity_probe: fn -> nil end)

    try do
      supported = resolve!("anthropic:supported", config, snapshot)
      unsupported = resolve!("anthropic:unsupported", config, snapshot)

      ensure!(
        ModelSelection.image_tool_result_delivery(supported) == :supported,
        "supported route was not exact"
      )

      ensure!(
        ModelSelection.image_tool_result_delivery(unsupported) ==
          {:unsupported, :tool_result_transport},
        "unsupported route did not retain the transport gate"
      )

      run_case("supported-image", supported, config, project, subscriber)
      run_case("unsupported-image", unsupported, config, project, subscriber)

      receive do
        {:retained_image_server_complete, observations} ->
          IO.puts(
            JSON.encode!(%{
              status: "ok",
              image_bytes: byte_size(image),
              supported_wire_bytes_matched: observations.supported_bytes,
              unsupported_tool_error_visible: observations.unsupported_error,
              unsupported_wire_image_absent: observations.unsupported_no_image
            })
          )
      after
        @timeout -> raise "loopback server did not complete four native requests"
      end

      :ok
    after
      case previous_key do
        nil -> System.delete_env("ANTHROPIC_API_KEY")
        value -> System.put_env("ANTHROPIC_API_KEY", value)
      end

      stop_linked_process(server)
      stop_linked_process(subscriber)
      stop_server(store)
      stop_server(quota)
      :gen_tcp.close(listener)
      File.rm_rf!(root)
    end
  end

  @spec resolve!(String.t(), Config.t(), Snapshot.t()) :: ModelSelection.t()
  defp resolve!(intent, config, snapshot) do
    {:ok, selection} =
      ModelResolver.resolve(intent,
        config: config,
        credential_snapshot: snapshot,
        backend_spec: NativePack.spec(),
        providers: []
      )

    selection
  end

  @spec run_case(String.t(), ModelSelection.t(), Config.t(), String.t(), pid()) :: :ok
  defp run_case(request_id, selection, config, project, subscriber) do
    {:ok, provider} =
      Native.start_link(
        subscriber: subscriber,
        model: ModelSelection.id(selection),
        model_selection: selection,
        config: config,
        project_root: project,
        tools: Tools.all(project_root: project),
        read_only?: true,
        max_retries: 0
      )

    request =
      Request.new(request_id, 1, 0, [Context.user("Read retained.png and describe the result")])

    try do
      :ok = Native.send_prompt(provider, request)
      await_completion!(request_id)
    after
      if Process.alive?(provider), do: GenServer.stop(provider)
    end
  end

  @spec smoke_config(:inet.port_number()) :: Config.t()
  defp smoke_config(port) do
    common = %{
      "name" => "Native retained image smoke",
      "provider_model_id" => "wire-retained-image",
      "reasoning_options" => ["off"],
      "limits" => %{"context" => 32_000, "output" => 512},
      "capabilities" => %{"tools" => true, "images" => true, "streaming" => true}
    }

    supported = put_in(common, ["capabilities", "tool_result_images"], true)

    endpoint = %{
      "url" => "http://127.0.0.1:#{port}",
      "protocol" => "anthropic_messages",
      "auth_mode" => "api_key",
      "models" => %{"supported" => supported, "unsupported" => common}
    }

    %Config{api_endpoints: %{"anthropic" => endpoint}, max_tokens: 512}
  end

  @spec subscriber_loop(pid(), GenServer.server()) :: no_return()
  defp subscriber_loop(owner, store) do
    receive do
      {:agent_provider_event, request_id, event} ->
        send(owner, {:smoke_event, request_id, event})
        subscriber_loop(owner, store)

      {:"$gen_call", from, {:checkpoint_tool_group, request_id, _messages, _calls}} ->
        GenServer.reply(from, {:ok, "checkpoint-" <> request_id})
        subscriber_loop(owner, store)

      {:"$gen_call", from,
       {:admit_tool_effect, _request_id, _checkpoint_id, _tool_call_id, _name, _args}} ->
        GenServer.reply(from, {:ok, store})
        subscriber_loop(owner, store)

      {:"$gen_call", from,
       {:complete_tool_effect, _request_id, _checkpoint_id, _tool_call_id, _message}} ->
        GenServer.reply(from, :ok)
        subscriber_loop(owner, store)

      {:"$gen_call", from, :artifact_store} ->
        GenServer.reply(from, {:ok, store})
        subscriber_loop(owner, store)

      {:"$gen_call", from, :dequeue_steering_messages} ->
        GenServer.reply(from, [])
        subscriber_loop(owner, store)
    end
  end

  @spec await_completion!(String.t()) :: :ok
  defp await_completion!(request_id) do
    receive do
      {:smoke_event, ^request_id, %Event.AgentEnd{outcome: %MingaAgent.Session.Outcome{}}} ->
        :ok

      {:smoke_event, ^request_id, %Event.Error{message: message}} ->
        raise "native image smoke failed: #{message}"

      {:smoke_event, ^request_id, _event} ->
        await_completion!(request_id)
    after
      @timeout -> raise "native image smoke timed out for #{request_id}"
    end
  end

  @spec serve_requests(port(), pid(), binary(), 1 | 2 | 3 | 4) :: no_return()
  defp serve_requests(listener, parent, expected_image, index) do
    {:ok, socket} = :gen_tcp.accept(listener, @timeout)
    request = receive_http_request!(socket)
    ensure!(request.method == "POST", "expected POST at the Anthropic boundary")
    ensure!(request.target == "/v1/messages", "unexpected Anthropic target #{request.target}")

    response =
      case index do
        1 ->
          assert_initial_request!(request.body)
          anthropic_tool_response("tool_supported")

        2 ->
          assert_supported_image!(request.body, expected_image)
          anthropic_text_response("supported image received")

        3 ->
          assert_initial_request!(request.body)
          anthropic_tool_response("tool_unsupported")

        4 ->
          assert_unsupported_error!(request.body)
          anthropic_text_response("unsupported image handled")
      end

    :ok = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)

    if index == 4 do
      send(parent, {
        :retained_image_server_complete,
        %{supported_bytes: true, unsupported_error: true, unsupported_no_image: true}
      })

      exit(:normal)
    else
      serve_requests(listener, parent, expected_image, index + 1)
    end
  end

  @spec assert_initial_request!(map()) :: :ok
  defp assert_initial_request!(body) do
    ensure!(find_tool_result(body) == nil, "initial request unexpectedly contained a tool result")
  end

  @spec assert_supported_image!(map(), binary()) :: :ok
  defp assert_supported_image!(body, expected_image) do
    tool_result = find_tool_result(body)
    ensure!(is_map(tool_result), "supported continuation omitted the tool result")
    image = Enum.find(tool_result["content"], &(&1["type"] == "image"))
    ensure!(is_map(image), "supported continuation omitted the nested image")
    ensure!(image["source"]["media_type"] == "image/png", "wire media type was not PNG")

    ensure!(
      Base.decode64!(image["source"]["data"]) == expected_image,
      "wire image bytes differ from the retained PNG"
    )
  end

  @spec assert_unsupported_error!(map()) :: :ok
  defp assert_unsupported_error!(body) do
    tool_result = find_tool_result(body)
    ensure!(is_map(tool_result), "unsupported continuation omitted the tool result")

    content =
      case tool_result["content"] do
        text when is_binary(text) -> [%{"type" => "text", "text" => text}]
        parts when is_list(parts) -> parts
      end

    ensure!(
      Enum.all?(content, &(&1["type"] != "image")),
      "unsupported route received image bytes"
    )

    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])

    ensure!(
      text =~ "selected protocol does not support images in tool results",
      "unsupported route did not receive the explicit tool limitation"
    )
  end

  @spec find_tool_result(map()) :: map() | nil
  defp find_tool_result(body) do
    body
    |> Map.get("messages", [])
    |> Enum.flat_map(fn message -> List.wrap(message["content"]) end)
    |> Enum.find(fn
      %{"type" => "tool_result"} -> true
      _content -> false
    end)
  end

  @spec receive_http_request!(port()) :: map()
  defp receive_http_request!(socket) do
    {header_bytes, body_prefix} = receive_headers!(socket, "")
    [request_line | header_lines] = String.split(header_bytes, "\r\n", trim: true)
    [method, target, _version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    content_length = headers |> Map.fetch!("content-length") |> String.to_integer()
    body = receive_body!(socket, body_prefix, content_length)
    %{method: method, target: target, body: JSON.decode!(body)}
  end

  @spec receive_headers!(port(), binary()) :: {binary(), binary()}
  defp receive_headers!(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        {headers, body}

      [_incomplete] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, @timeout)
        receive_headers!(socket, bytes <> chunk)
    end
  end

  @spec receive_body!(port(), binary(), non_neg_integer()) :: binary()
  defp receive_body!(_socket, bytes, length) when byte_size(bytes) >= length,
    do: binary_part(bytes, 0, length)

  defp receive_body!(socket, bytes, length) do
    {:ok, chunk} = :gen_tcp.recv(socket, length - byte_size(bytes), @timeout)
    receive_body!(socket, bytes <> chunk, length)
  end

  @spec anthropic_tool_response(String.t()) :: iodata()
  defp anthropic_tool_response(tool_id) do
    events = [
      %{"type" => "message_start", "message" => %{"id" => "msg_#{tool_id}"}},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => tool_id,
          "name" => "read_file",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => ~s({"path":"retained.png"})
        }
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 1}
      },
      %{"type" => "message_stop"}
    ]

    sse_response(events)
  end

  @spec anthropic_text_response(String.t()) :: iodata()
  defp anthropic_text_response(text) do
    events = [
      %{"type" => "message_start", "message" => %{"id" => "msg_final"}},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 1}
      },
      %{"type" => "message_stop"}
    ]

    sse_response(events)
  end

  @spec sse_response([map()]) :: iodata()
  defp sse_response(events) do
    body = Enum.map_join(events, "", &"event: #{&1["type"]}\ndata: #{JSON.encode!(&1)}\n\n")

    [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  @spec valid_png() :: binary()
  defp valid_png do
    width = 256
    height = 256

    pixels =
      for index <- 0..6_143, into: <<>> do
        :crypto.hash(:sha256, <<index::unsigned-big-64>>)
      end

    scanlines =
      for row <- 0..(height - 1), into: <<>> do
        row_pixels = binary_part(pixels, row * width * 3, width * 3)
        <<0, row_pixels::binary>>
      end

    signature = <<137, 80, 78, 71, 13, 10, 26, 10>>
    ihdr = <<width::unsigned-big-32, height::unsigned-big-32, 8, 2, 0, 0, 0>>

    signature <>
      png_chunk("IHDR", ihdr) <>
      png_chunk("IDAT", :zlib.compress(scanlines)) <>
      png_chunk("IEND", "")
  end

  @spec png_chunk(binary(), binary()) :: binary()
  defp png_chunk(type, data) do
    length = byte_size(data)
    crc = :erlang.crc32(type <> data)
    <<length::unsigned-big-32, type::binary, data::binary, crc::unsigned-big-32>>
  end

  @spec stop_server(pid()) :: :ok
  defp stop_server(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  @spec stop_linked_process(pid()) :: :ok
  defp stop_linked_process(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    :ok
  end

  @spec ensure!(boolean(), String.t()) :: :ok
  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(message)
end

Minga.Smoke.NativeRetainedImage.run()
