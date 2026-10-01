defmodule Minga.Smoke.NativeModelRoute do
  @moduledoc false

  alias MingaAgent.Config
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.Event
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection
  alias MingaAgent.ProviderPacks.Native, as: NativePack
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session.Request
  alias ReqLLM.Context

  @timeout 10_000
  @sentinel_key "minga-local-smoke-key"

  @spec run() :: :ok
  def run do
    {:ok, _apps} = Application.ensure_all_started(:req_llm)
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    previous_openai_key = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", @sentinel_key)
    parent = self()
    server = spawn_link(fn -> serve_once(listener, parent) end)
    config = smoke_config(port)
    snapshot = Snapshot.new(%{"openai" => :env}, nil, "http://127.0.0.1:#{port}")

    {:ok, selection} =
      ModelResolver.resolve("openai:route-check",
        config: config,
        credential_snapshot: snapshot,
        backend_spec: NativePack.spec()
      )

    assert_selection!(selection, port)

    {:ok, provider} =
      Native.start_link(
        subscriber: self(),
        model: ModelSelection.id(selection),
        model_selection: selection,
        config: config,
        project_root: File.cwd!(),
        tools: [],
        read_only?: true
      )

    request = Request.new("route-smoke", 1, 0, [Context.user("Reply with route-ok")])

    try do
      :ok = Native.send_prompt(provider, request)
      observed = receive_request!()
      assert_request!(observed)
      response = await_completion!([])
      ensure!(response == "route-ok", "unexpected streamed response: #{inspect(response)}")

      IO.puts(
        JSON.encode!(%{
          status: "ok",
          endpoint: observed.target,
          authorization_header: "present_and_matched",
          request_model: observed.body["model"],
          response: response
        })
      )

      :ok
    after
      if Process.alive?(provider), do: GenServer.stop(provider)
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
      restore_env("OPENAI_API_KEY", previous_openai_key)
    end
  end

  @spec smoke_config(:inet.port_number()) :: Config.t()
  defp smoke_config(port) do
    endpoint = %{
      "url" => "http://127.0.0.1:#{port}/v1",
      "protocol" => "openai_chat",
      "auth_mode" => "api_key",
      "models" => %{
        "route-check" => %{
          "name" => "Native route smoke",
          "provider_model_id" => "wire-route-check",
          "reasoning_options" => ["off"],
          "limits" => %{"context" => 8_192, "output" => 256},
          "capabilities" => %{"tools" => true, "images" => false, "streaming" => true}
        }
      }
    }

    %Config{api_endpoints: %{"openai" => endpoint}, max_tokens: 256}
  end

  @spec assert_selection!(ModelSelection.t(), :inet.port_number()) :: :ok
  defp assert_selection!(selection, port) do
    expected_url = "http://127.0.0.1:#{port}/v1"

    ensure!(selection.route.execution.base_url == expected_url, "resolver changed the endpoint")
    ensure!(selection.route.execution.path == "/chat/completions", "resolver changed the path")

    ensure!(
      selection.route.execution.provider_model_id == "wire-route-check",
      "resolver changed the wire model id"
    )

    ensure!(
      ModelSelection.credential_id(selection.credential) == "openai:env",
      "resolver changed the exact API-key credential identity"
    )
  end

  @spec serve_once(port(), pid()) :: no_return()
  defp serve_once(listener, parent) do
    {:ok, socket} = :gen_tcp.accept(listener, @timeout)
    request = receive_http_request!(socket)
    send(parent, {:route_smoke_request, request})
    :ok = :gen_tcp.send(socket, http_response())
    :gen_tcp.close(socket)
    exit(:normal)
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

    content_length = headers |> Map.get("content-length", "0") |> String.to_integer()
    body = receive_body!(socket, body_prefix, content_length)

    %{method: method, target: target, headers: headers, body: JSON.decode!(body)}
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
  defp receive_body!(_socket, bytes, content_length) when byte_size(bytes) >= content_length,
    do: binary_part(bytes, 0, content_length)

  defp receive_body!(socket, bytes, content_length) do
    {:ok, chunk} = :gen_tcp.recv(socket, content_length - byte_size(bytes), @timeout)
    receive_body!(socket, bytes <> chunk, content_length)
  end

  @spec http_response() :: iodata()
  defp http_response do
    body =
      [
        ~s(data: {"id":"chatcmpl-route-smoke","object":"chat.completion.chunk","created":0,"model":"wire-route-check","choices":[{"index":0,"delta":{"role":"assistant","content":"route-ok"},"finish_reason":null}]}\n\n),
        ~s(data: {"id":"chatcmpl-route-smoke","object":"chat.completion.chunk","created":0,"model":"wire-route-check","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
        "data: [DONE]\n\n"
      ]
      |> IO.iodata_to_binary()

    [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  @spec receive_request!() :: map()
  defp receive_request! do
    receive do
      {:route_smoke_request, request} -> request
    after
      @timeout -> raise "Minga did not reach the local route smoke endpoint"
    end
  end

  @spec assert_request!(map()) :: :ok
  defp assert_request!(request) do
    ensure!(request.method == "POST", "expected POST, got #{inspect(request.method)}")

    ensure!(
      request.target == "/v1/chat/completions",
      "expected /v1/chat/completions, got #{inspect(request.target)}"
    )

    ensure!(
      request.headers["authorization"] == "Bearer #{@sentinel_key}",
      "API-key route did not send its exact Authorization header"
    )

    ensure!(
      request.body["model"] == "wire-route-check",
      "expected wire-route-check, got #{inspect(request.body["model"])}"
    )
  end

  @spec await_completion!([String.t()]) :: String.t()
  defp await_completion!(chunks) do
    receive do
      {:agent_provider_event, "route-smoke", %Event.TextDelta{delta: delta}} ->
        await_completion!([delta | chunks])

      {:agent_provider_event, "route-smoke",
       %Event.AgentEnd{outcome: %MingaAgent.Session.Outcome{}}} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()

      {:agent_provider_event, "route-smoke", %Event.Error{message: message}} -> raise message
      _event -> await_completion!(chunks)
    after
      @timeout -> raise "Minga did not complete the local route smoke request"
    end
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  @spec ensure!(boolean(), String.t()) :: :ok
  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(message)
end

Minga.Smoke.NativeModelRoute.run()
