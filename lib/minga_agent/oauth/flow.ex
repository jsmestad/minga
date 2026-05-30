defmodule MingaAgent.OAuth.Flow do
  @moduledoc """
  Orchestrates the OpenAI OAuth acquisition flow.

  Generates PKCE credentials, starts a Bandit callback server, opens
  the browser, waits for the redirect, exchanges the code, and writes
  the tokens to `oauth.json`. Runs as a synchronous function intended
  to be called inside a Task under `Minga.Eval.TaskSupervisor`.
  """

  alias MingaAgent.OAuth

  @flow_timeout_ms 120_000

  @doc """
  Runs the full OAuth acquisition flow synchronously.

  Returns:
  - `{:ok, :openai}` on success (tokens written to oauth.json)
  - `{:browser_failed, url}` if the browser could not be opened
  - `{:error, reason}` on any failure

  The caller is responsible for wrapping this in a Task if async
  execution is needed.
  """
  @spec run() :: {:ok, :openai} | {:browser_failed, String.t()} | {:error, String.t()}
  def run do
    pkce = OAuth.generate_pkce()
    state = generate_state()
    config = OAuth.openai_config()

    case register_flow() do
      :ok -> run_registered_flow(pkce, state, config)
      {:error, reason} -> {:error, reason}
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
              {:browser_failed, url}
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

  defp await_and_exchange(expected_state, verifier, port) do
    receive do
      {:oauth_callback, code, state} when is_binary(code) and state == expected_state ->
        exchange_and_persist(code, verifier, port)

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

  defp exchange_and_persist(code, verifier, port) do
    with {:ok, tokens} <- OAuth.exchange_code(code, verifier, port),
         :ok <- OAuth.write_oauth_file(tokens) do
      {:ok, :openai}
    end
  end
end
