defmodule MingaAgent.OAuth.Flow do
  @moduledoc """
  Orchestrates the OpenAI OAuth acquisition flow.

  Generates PKCE credentials, starts a Bandit callback server, opens
  the browser, waits for the redirect, exchanges the code, and writes
  the tokens to `oauth.json`. Runs as a synchronous function intended
  to be called inside a Task under `Minga.Eval.TaskSupervisor`.
  """

  alias MingaAgent.OAuth
  alias MingaAgent.OAuth.CallbackHandler
  alias MingaAgent.OAuth.PendingFlow

  @flow_timeout_ms 120_000

  @type run_result ::
          {:ok, :openai} | {:manual_required, String.t(), String.t()} | {:error, String.t()}
  @type complete_result :: {:ok, :openai} | {:error, String.t()}
  @type exchange_fun :: (String.t(), String.t(), pos_integer() ->
                           {:ok, OAuth.token_response()} | {:error, String.t()})
  @type write_fun :: (OAuth.token_response() -> :ok | {:error, String.t()})

  @doc """
  Runs the full OAuth acquisition flow synchronously.

  Returns:
  - `{:ok, :openai}` on success (tokens written to oauth.json)
  - `{:manual_required, url, ref}` if the browser could not be opened and the server is waiting for paste-back completion
  - `{:error, reason}` on any failure

  The caller is responsible for wrapping this in a Task if async
  execution is needed.
  """
  @spec run() :: run_result()
  def run do
    pkce = OAuth.generate_pkce()
    state = generate_state()
    config = OAuth.openai_config()

    case register_flow() do
      :ok -> run_registered_flow(pkce, state, config)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Begins a manual paste-back OAuth flow without starting a local callback server."
  @spec begin_manual(keyword()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def begin_manual(opts \\ []) do
    pkce = OAuth.generate_pkce()
    state = generate_state()
    config = OAuth.openai_config()
    port = Keyword.get(opts, :port, config.port)
    timeout_ms = Keyword.get(opts, :timeout_ms, @flow_timeout_ms)
    url = OAuth.openai_authorize_url(pkce.challenge, state, port)
    owner_session_id = Keyword.get(opts, :session_id)
    owner_client_pid = Keyword.get(opts, :client_pid)

    begin_manual_flow(
      url,
      pkce.verifier,
      state,
      port,
      timeout_ms,
      owner_session_id,
      owner_client_pid
    )
  end

  @doc "Completes a manual paste-back OAuth flow from a pasted redirect value."
  @spec complete_manual(String.t(), String.t(), keyword()) :: complete_result()
  def complete_manual(ref, pasted, opts \\ []) when is_binary(ref) and is_binary(pasted) do
    exchange_fun = Keyword.get(opts, :exchange_fun, &OAuth.exchange_code/3)
    write_fun = Keyword.get(opts, :write_fun, &OAuth.write_oauth_file/1)

    with {:ok, event} <- parse_manual_callback(pasted),
         {:ok, pending} <- pending_flow(ref),
         :ok <-
           validate_pending_owner(
             pending,
             Keyword.get(opts, :session_id),
             Keyword.get(opts, :client_pid)
           ),
         {:ok, code} <- validate_manual_event(event, pending) do
      exchange_and_persist(code, pending.verifier, pending.port, exchange_fun, write_fun)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp generate_state do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp run_registered_flow(pkce, state, config) do
    case start_server(config.port, config.fallback_port) do
      {:ok, bandit_pid, port} ->
        try do
          url = OAuth.openai_authorize_url(pkce.challenge, state, port)

          case open_browser(url) do
            :ok ->
              await_and_exchange(state, pkce.verifier, port)

            {:error, _reason} ->
              case begin_manual_flow(url, pkce.verifier, state, port, @flow_timeout_ms, nil, nil) do
                {:ok, manual_url, ref} -> {:manual_required, manual_url, ref}
                {:error, reason} -> {:error, reason}
              end
          end
        after
          stop_server(bandit_pid)
          unregister_flow()
        end

      {:error, reason} ->
        unregister_flow()
        {:error, reason}
    end
  end

  defp register_flow do
    case Process.whereis(:minga_oauth_flow) do
      nil ->
        Process.register(self(), :minga_oauth_flow)
        :ok

      _pid ->
        {:error, "Another OAuth flow is already in progress"}
    end
  rescue
    ArgumentError -> {:error, "Another OAuth flow is already in progress"}
  end

  defp unregister_flow do
    Process.unregister(:minga_oauth_flow)
  rescue
    ArgumentError -> :ok
  end

  defp start_server(port, fallback_port) do
    case start_server_on_port(port) do
      {:ok, pid} -> {:ok, pid, port}
      {:error, :eaddrinuse} -> start_fallback_server(port, fallback_port)
      {:error, {:start_failed, reason}} -> {:error, start_failed_message(port, reason)}
    end
  end

  defp start_fallback_server(port, fallback_port) do
    case start_server_on_port(fallback_port) do
      {:ok, pid} ->
        {:ok, pid, fallback_port}

      {:error, :eaddrinuse} ->
        {:error,
         "Ports #{port} and #{fallback_port} are already in use. Free one of those ports or use /auth with an API key instead."}

      {:error, {:start_failed, reason}} ->
        {:error, start_failed_message(fallback_port, reason)}
    end
  end

  defp start_server_on_port(port) do
    case Bandit.start_link(
           plug: MingaAgent.OAuth.CallbackHandler,
           port: port,
           ip: {127, 0, 0, 1},
           thousand_island_options: [num_acceptors: 1]
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:shutdown, {:failed_to_start_child, :listener, {:listen, :eaddrinuse}}}} ->
        {:error, :eaddrinuse}

      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  end

  defp start_failed_message(port, reason) do
    "Could not start callback server on port #{port}: #{inspect(reason)}. Free the port or use /auth with an API key instead."
  end

  defp stop_server(pid) when is_pid(pid) do
    Supervisor.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp open_browser(url) do
    {cmd, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
      end

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "#{cmd} exited with #{code}: #{output}"}
    end
  rescue
    e in [ErlangError] -> {:error, "Failed to open browser: #{Exception.message(e)}"}
  end

  @spec begin_manual_flow(
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t() | nil,
          pid() | nil
        ) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  defp begin_manual_flow(
         url,
         verifier,
         state,
         port,
         timeout_ms,
         owner_session_id,
         owner_client_pid
       ) do
    flow = PendingFlow.Entry.new(verifier, state, port, owner_session_id, owner_client_pid)

    case PendingFlow.put(flow, timeout_ms) do
      {:ok, ref} -> {:ok, url, ref}
      {:error, reason} -> {:error, "Could not start manual OAuth flow: #{inspect(reason)}"}
    end
  end

  @spec parse_manual_callback(String.t()) ::
          {:ok,
           {:oauth_callback, String.t(), String.t() | nil}
           | {:oauth_callback_error, {:provider_error, String.t()} | :missing_code}}
          | {:error, String.t()}
  defp parse_manual_callback(pasted) do
    pasted
    |> String.trim()
    |> parse_manual_callback_value()
  end

  @spec parse_manual_callback_value(String.t()) ::
          {:ok,
           {:oauth_callback, String.t(), String.t() | nil}
           | {:oauth_callback_error, {:provider_error, String.t()} | :missing_code}}
          | {:error, String.t()}
  defp parse_manual_callback_value(""),
    do: {:error, "No redirect value was provided. Run /login --manual to try again."}

  defp parse_manual_callback_value(value) do
    value
    |> URI.parse()
    |> parse_manual_uri(value)
  end

  @spec parse_manual_uri(URI.t(), String.t()) ::
          {:ok,
           {:oauth_callback, String.t(), String.t() | nil}
           | {:oauth_callback_error, {:provider_error, String.t()} | :missing_code}}
          | {:error, String.t()}
  defp parse_manual_uri(%URI{query: query}, _value) when is_binary(query) and query != "" do
    query
    |> URI.decode_query()
    |> CallbackHandler.callback_event()
    |> then(&{:ok, &1})
  end

  defp parse_manual_uri(_uri, value), do: parse_manual_blob(value)

  @spec parse_manual_blob(String.t()) ::
          {:ok,
           {:oauth_callback, String.t(), String.t() | nil}
           | {:oauth_callback_error, {:provider_error, String.t()} | :missing_code}}
          | {:error, String.t()}
  defp parse_manual_blob(value) do
    value
    |> split_manual_blob()
    |> CallbackHandler.callback_event()
    |> then(&{:ok, &1})
  end

  @spec split_manual_blob(String.t()) :: map()
  defp split_manual_blob(value) do
    case String.split(value, "#", parts: 2) do
      [code, state] -> %{"code" => code, "state" => state}
      [_single] -> split_ampersand_blob(value)
    end
  end

  @spec split_ampersand_blob(String.t()) :: map()
  defp split_ampersand_blob(value) do
    case String.split(value, "&", parts: 2) do
      [code, state] -> %{"code" => code, "state" => state}
      [code] -> %{"code" => code}
    end
  end

  @spec pending_flow(String.t()) :: {:ok, PendingFlow.flow()} | {:error, String.t()}
  defp pending_flow(ref) do
    case PendingFlow.take(ref) do
      {:ok, pending} -> {:ok, pending}
      {:error, :expired_flow} -> {:error, "OAuth flow expired. Run /login --manual to try again."}
      {:error, :unknown_flow} -> {:error, "Unknown OAuth flow. Run /login --manual to try again."}
      {:error, reason} -> {:error, "Could not read OAuth flow: #{inspect(reason)}"}
    end
  end

  @spec validate_pending_owner(PendingFlow.flow(), String.t() | nil, pid() | nil) ::
          :ok | {:error, String.t()}
  defp validate_pending_owner(
         %{owner_session_id: nil, owner_client_pid: nil},
         _session_id,
         _client_pid
       ),
       do: :ok

  defp validate_pending_owner(
         %{owner_session_id: session_id, owner_client_pid: client_pid},
         session_id,
         client_pid
       ),
       do: :ok

  defp validate_pending_owner(_pending, _session_id, _client_pid) do
    {:error,
     "OAuth flow belongs to a different remote session. Run /login --manual to try again."}
  end

  @spec validate_manual_event(
          {:oauth_callback, String.t(), String.t() | nil}
          | {:oauth_callback_error, {:provider_error, String.t()} | :missing_code},
          PendingFlow.flow()
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp validate_manual_event({:oauth_callback, code, state}, pending)
       when state == pending.state do
    {:ok, code}
  end

  defp validate_manual_event({:oauth_callback, code, nil}, _pending), do: {:ok, code}

  defp validate_manual_event({:oauth_callback, _code, _wrong_state}, _pending) do
    {:error, "OAuth state mismatch (possible CSRF). Run /login --manual to try again."}
  end

  defp validate_manual_event({:oauth_callback_error, {:provider_error, message}}, _pending) do
    {:error, "Authorization failed: #{message}. Run /login --manual to try again."}
  end

  defp validate_manual_event({:oauth_callback_error, :missing_code}, _pending) do
    {:error, "Authorization was denied or failed. Run /login --manual to try again."}
  end

  defp await_and_exchange(expected_state, verifier, port) do
    receive do
      {:oauth_callback, code, state} when is_binary(code) and state == expected_state ->
        exchange_and_persist(
          code,
          verifier,
          port,
          &OAuth.exchange_code/3,
          &OAuth.write_oauth_file/1
        )

      {:oauth_callback, _code, nil} ->
        {:error, "OAuth redirect was missing the state parameter. Run /login to try again."}

      {:oauth_callback, _code, _wrong_state} ->
        {:error, "OAuth state mismatch (possible CSRF). Run /login to try again."}

      {:oauth_callback_error, {:provider_error, message}} ->
        {:error, "Authorization failed: #{message}. Run /login to try again."}

      {:oauth_callback_error, :missing_code} ->
        {:error, "Authorization was denied or failed. Run /login to try again."}
    after
      @flow_timeout_ms ->
        {:error,
         "Authentication timed out after #{div(@flow_timeout_ms, 1000)} seconds. Run /login to try again."}
    end
  end

  @spec exchange_and_persist(String.t(), String.t(), pos_integer(), exchange_fun(), write_fun()) ::
          complete_result()
  defp exchange_and_persist(code, verifier, port, exchange_fun, write_fun) do
    with {:ok, tokens} <- exchange_fun.(code, verifier, port),
         :ok <- write_fun.(tokens) do
      {:ok, :openai}
    end
  end
end
