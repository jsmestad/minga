defmodule MingaAgent.OAuth.Flow do
  @moduledoc """
  Orchestrates the OpenAI OAuth acquisition flow.

  Generates PKCE credentials, starts a Bandit callback server, opens
  the browser, waits for the redirect, exchanges the code, and writes
  the tokens to `oauth.json`. Runs as a synchronous function intended
  to be called inside a Task under `Minga.Eval.TaskSupervisor`.
  """

  alias MingaAgent.Credentials.Secret
  alias MingaAgent.OAuth
  alias MingaAgent.OAuth.CallbackHandler
  alias MingaAgent.OAuth.PendingFlow
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionTarget

  @flow_timeout_ms 120_000
  @binding_timeout_ms 5_000

  @type run_result ::
          {:ok, :openai}
          | {:manual_required, String.t(), String.t()}
          | {:error, String.t() | atom()}
  @type complete_result :: {:ok, :openai} | {:error, String.t() | atom()}
  @type exchange_fun :: (String.t(), String.t(), pos_integer() ->
                           {:ok, OAuth.token_response()} | {:error, String.t()})
  @type write_fun :: (OAuth.token_response() -> :ok | {:error, String.t() | atom()})
  @type connection_result :: {:ok, :openai} | {:error, atom()}

  @doc "Acquires OAuth material only after Session admits this exact worker."
  @spec run_connection(
          ConnectionTarget.t(),
          reference(),
          :oauth_browser | :oauth_manual,
          pid(),
          (MingaAgent.OAuth.ManualReady.t() -> term()),
          keyword()
        ) ::
          connection_result()
  def run_connection(%ConnectionTarget{} = target, ref, method, owner, notify_manual, opts \\ []) do
    Process.flag(:sensitive, true)
    owner_monitor = Process.monitor(owner)
    session_monitor = Process.monitor(target.session)
    monitors = {owner_monitor, session_monitor}

    bound_opts = [
      operation_ref: ref,
      session_id: target.session_id,
      client_pid: owner,
      monitors: monitors,
      write_fun: fn tokens ->
        case Session.commit_oauth(target.session, target, ref, Secret.new(tokens)) do
          {:ok, _snapshot} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    ]

    opts = Keyword.merge(Keyword.take(opts, [:exchange_fun, :launch_fun]), bound_opts)

    try do
      with :ok <- await_binding(ref, monitors) do
        case acquire(method, opts) do
          {:manual_required, url, flow_ref} ->
            notify_manual.(MingaAgent.OAuth.ManualReady.new(target, ref, self(), flow_ref, url))

            await_manual(
              ref,
              flow_ref,
              opts,
              System.monotonic_time(:millisecond) + @flow_timeout_ms
            )

          result ->
            safe_result(result, :authorization_failed)
        end
      end
    catch
      :exit, _reason -> {:error, :session_unavailable}
    after
      PendingFlow.cancel_operation(ref, {target.session_id, owner})
      Process.demonitor(owner_monitor, [:flush])
      Process.demonitor(session_monitor, [:flush])
    end
  end

  @doc "Submits sealed input and waits for the exact acquisition result."
  @spec complete_connection(pid(), reference(), String.t(), Secret.t()) :: connection_result()
  def complete_connection(worker, ref, flow_ref, secret) do
    monitor = Process.monitor(worker, alias: :demonitor)

    try do
      send(worker, {:oauth_manual_complete, monitor, ref, flow_ref, secret})

      receive do
        {:oauth_manual_result, ^monitor, result} -> result
        {:DOWN, ^monitor, :process, ^worker, _reason} -> {:error, :worker_unavailable}
      after
        150_000 -> {:error, :completion_timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  @doc """
  Runs the full OAuth acquisition flow synchronously.

  Returns:
  - `{:ok, :openai}` on success (tokens written to oauth.json)
  - `{:manual_required, url, ref}` if the browser could not be opened and the server is waiting for paste-back completion
  - `{:error, reason}` on any failure

  The caller is responsible for wrapping this in a Task if async
  execution is needed.
  """
  @spec run(keyword()) :: run_result()
  def run(opts \\ []) do
    pkce = OAuth.generate_pkce()
    state = generate_state()
    config = OAuth.openai_config()

    case register_flow() do
      :ok -> run_registered_flow(pkce, state, config, opts)
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
      owner_client_pid,
      opts
    )
  end

  @doc "Completes a manual paste-back OAuth flow from a pasted redirect value."
  @spec complete_manual(String.t(), String.t(), keyword()) :: complete_result()
  def complete_manual(ref, pasted, opts \\ []) when is_binary(ref) and is_binary(pasted) do
    exchange_fun = Keyword.get(opts, :exchange_fun, &OAuth.exchange_code/3)
    write_fun = Keyword.get(opts, :write_fun, &OAuth.write_oauth_file/1)

    with {:ok, event} <- parse_manual_callback(pasted),
         {:ok, {pending, bound_writer, _operation_ref}} <- pending_flow(ref, opts),
         {:ok, code} <- validate_manual_event(event, pending) do
      exchange_and_persist(
        code,
        pending.verifier,
        pending.port,
        exchange_fun,
        bound_writer || write_fun
      )
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec await_binding(reference(), {reference(), reference()}) :: :ok | {:error, atom()}
  defp await_binding(ref, {owner_monitor, session_monitor}) do
    receive do
      {:connection_worker_binding, ^ref, result} ->
        result

      {:connection_cancelled, ^ref} ->
        {:error, :cancelled}

      {:DOWN, monitor, :process, _pid, _reason}
      when monitor in [owner_monitor, session_monitor] ->
        {:error, :session_unavailable}
    after
      @binding_timeout_ms -> {:error, :worker_unavailable}
    end
  end

  @spec acquire(:oauth_browser | :oauth_manual, keyword()) :: run_result() | {:error, atom()}
  defp acquire(:oauth_browser, opts), do: run(opts)

  defp acquire(:oauth_manual, opts) do
    case begin_manual(opts) do
      {:ok, url, ref} -> {:manual_required, url, ref}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec await_manual(reference(), String.t(), keyword(), integer()) :: connection_result()
  defp await_manual(ref, flow_ref, opts, deadline) do
    {owner_monitor, session_monitor} = Keyword.fetch!(opts, :monitors)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:oauth_manual_complete, reply, ^ref, ^flow_ref, secret}
      when is_reference(reply) ->
        result = Secret.complete_manual_oauth(secret, flow_ref, opts)
        send(reply, {:oauth_manual_result, reply, result})

        case result do
          {:error, :invalid_input} -> await_manual(ref, flow_ref, opts, deadline)
          terminal -> terminal
        end

      {:oauth_manual_complete, reply, _other_ref, _other_flow, _secret}
      when is_reference(reply) ->
        send(reply, {:oauth_manual_result, reply, {:error, :refused}})
        await_manual(ref, flow_ref, opts, deadline)

      {:connection_cancelled, ^ref} ->
        {:error, :cancelled}

      {:DOWN, monitor, :process, _pid, _reason}
      when monitor in [owner_monitor, session_monitor] ->
        {:error, :session_unavailable}
    after
      remaining -> {:error, :expired}
    end
  end

  @doc false
  @spec complete_bound_manual(String.t(), String.t(), keyword()) :: connection_result()
  def complete_bound_manual(ref, pasted, opts) do
    case parse_manual_callback(pasted) do
      {:ok, event} -> complete_bound_event(ref, event, opts)
      {:error, _reason} -> {:error, :invalid_input}
    end
  end

  @spec complete_bound_event(String.t(), term(), keyword()) :: connection_result()
  defp complete_bound_event(ref, event, opts) do
    with {:ok, {pending, writer, operation}}
         when is_function(writer, 1) and is_reference(operation) <-
           PendingFlow.take(ref, opts),
         {:ok, code} <- validate_manual_event(event, pending) do
      exchange_fun = Keyword.get(opts, :exchange_fun, &OAuth.exchange_code/3)

      safe_result(
        exchange_and_persist(code, pending.verifier, pending.port, exchange_fun, writer),
        :exchange_failed
      )
    else
      {:error, :expired_flow} -> {:error, :expired}
      {:error, reason} when is_atom(reason) -> {:error, :refused}
      {:error, _reason} -> {:error, :authorization_failed}
      _invalid -> {:error, :refused}
    end
  end

  @spec safe_result(complete_result(), atom()) :: connection_result()
  defp safe_result({:ok, :openai}, _fallback), do: {:ok, :openai}
  defp safe_result({:error, reason}, _fallback) when is_atom(reason), do: {:error, reason}
  defp safe_result({:error, _reason}, fallback), do: {:error, fallback}

  defp generate_state do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp run_registered_flow(pkce, state, config, opts) do
    case start_server(config.port, config.fallback_port) do
      {:ok, bandit_pid, port} ->
        try do
          url = OAuth.openai_authorize_url(pkce.challenge, state, port)

          case launch_browser(url, opts) do
            :ok ->
              await_and_exchange(state, pkce.verifier, port, opts)

            {:interrupted, reason} ->
              {:error, reason}

            {:error, _reason} ->
              owner_id = Keyword.get(opts, :session_id)
              owner_pid = Keyword.get(opts, :client_pid)

              case begin_manual_flow(
                     url,
                     pkce.verifier,
                     state,
                     port,
                     @flow_timeout_ms,
                     owner_id,
                     owner_pid,
                     opts
                   ) do
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

  @spec launch_browser(String.t(), keyword()) ::
          :ok | {:error, String.t() | atom()} | {:interrupted, atom()}
  defp launch_browser(url, opts) do
    launch = Keyword.get(opts, :launch_fun, &open_browser/1)
    operation = Keyword.get(opts, :operation_ref)
    {owner_monitor, session_monitor} = Keyword.get(opts, :monitors, {nil, nil})
    parent = self()
    receipt = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {receipt, launch.(url)}) end)

    try do
      receive do
        {^receipt, result} ->
          result

        {:connection_cancelled, ^operation} when is_reference(operation) ->
          {:interrupted, :cancelled}

        {:DOWN, ref, :process, _pid, _reason} when ref in [owner_monitor, session_monitor] ->
          {:interrupted, :session_unavailable}

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          {:error, :launcher_unavailable}
      after
        @binding_timeout_ms -> {:error, :launcher_timeout}
      end
    after
      Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
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

  @doc "Opens the generated OpenAI authorization URL in the local browser."
  @spec open_browser(String.t()) :: :ok | {:error, String.t()}
  def open_browser("https://auth.openai.com/oauth/authorize?" <> _query = url) do
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

  def open_browser(_url), do: {:error, "Invalid OpenAI authorization URL."}

  @spec begin_manual_flow(
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t() | nil,
          pid() | nil,
          keyword()
        ) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  defp begin_manual_flow(
         url,
         verifier,
         state,
         port,
         timeout_ms,
         owner_session_id,
         owner_client_pid,
         opts
       ) do
    flow = PendingFlow.Entry.new(verifier, state, port, owner_session_id, owner_client_pid)

    case PendingFlow.put(flow, timeout_ms, Keyword.take(opts, [:operation_ref, :write_fun])) do
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

  @spec pending_flow(String.t(), keyword()) ::
          {:ok, PendingFlow.completion()} | {:error, String.t()}
  defp pending_flow(ref, opts) do
    case PendingFlow.take(ref, opts) do
      {:ok, pending} ->
        {:ok, pending}

      {:error, :expired_flow} ->
        {:error, "OAuth flow expired. Run /login --manual to try again."}

      {:error, :unknown_flow} ->
        {:error, "Unknown OAuth flow. Run /login --manual to try again."}

      {:error, :wrong_owner} ->
        {:error,
         "OAuth flow belongs to a different remote session. Run /login --manual to try again."}

      {:error, reason} ->
        {:error, "Could not read OAuth flow: #{inspect(reason)}"}
    end
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

  defp await_and_exchange(expected_state, verifier, port, opts) do
    operation_ref = Keyword.get(opts, :operation_ref)
    exchange_fun = Keyword.get(opts, :exchange_fun, &OAuth.exchange_code/3)
    writer = Keyword.get(opts, :write_fun, &OAuth.write_oauth_file/1)
    {owner_monitor, session_monitor} = Keyword.get(opts, :monitors, {nil, nil})

    receive do
      {:oauth_callback, code, state} when is_binary(code) and state == expected_state ->
        exchange_and_persist(code, verifier, port, exchange_fun, writer)

      {:connection_cancelled, ^operation_ref} when is_reference(operation_ref) ->
        {:error, :cancelled}

      {:DOWN, monitor, :process, _pid, _reason}
      when monitor in [owner_monitor, session_monitor] ->
        {:error, :session_unavailable}

      {:oauth_callback_error, _reason} when is_reference(operation_ref) ->
        {:error, :authorization_failed}

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
