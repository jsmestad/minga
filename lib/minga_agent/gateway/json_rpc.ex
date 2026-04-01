defmodule MingaAgent.Gateway.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 request dispatch.

  Pure function: decode request, call MingaAgent.Runtime, encode response.
  Easy to test in isolation without WebSocket machinery.

  ## Method naming

  Methods use dot notation following JSON-RPC convention:
    * `runtime.*` for introspection (capabilities, describe)
    * `session.*` for session lifecycle (start, stop, prompt, abort, list)
    * `tool.*` for tool operations (execute, list)

  ## Error codes

  Standard JSON-RPC 2.0 error codes:
    * `-32_700` parse error (malformed JSON)
    * `-32_600` invalid request (missing jsonrpc/method fields)
    * `-32_601` method not found
    * `-32_602` invalid params
    * `-32_603` internal error
  """

  alias MingaAgent.Runtime

  @spec dispatch(String.t()) :: {:ok, String.t()} | {:error, String.t()} | :notification
  def dispatch(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}} ->
        result = call_method(method, params)
        encode_result(id, result)

      {:ok, %{"jsonrpc" => "2.0", "method" => method, "id" => id}} ->
        result = call_method(method, %{})
        encode_result(id, result)

      {:ok, %{"jsonrpc" => "2.0", "method" => method, "params" => params}}
      when not is_map_key(params, "id") ->
        call_method(method, params)
        :notification

      {:ok, %{"jsonrpc" => "2.0", "method" => method}} when is_binary(method) ->
        call_method(method, %{})
        :notification

      {:ok, _} ->
        {:error, encode_error(nil, -32_600, "Invalid Request")}

      {:error, _} ->
        {:error, encode_error(nil, -32_700, "Parse error")}
    end
  end

  # ── Method dispatch ─────────────────────────────────────────────────────────

  @spec call_method(String.t(), map()) :: {:ok, term()} | {:error, {atom(), term()}}
  defp call_method("runtime.capabilities", _params) do
    {:ok, Runtime.capabilities()}
  end

  defp call_method("runtime.describe_tools", _params) do
    {:ok, Runtime.describe_tools()}
  end

  defp call_method("runtime.describe_sessions", _params) do
    {:ok, Runtime.describe_sessions()}
  end

  defp call_method("session.start", params) do
    opts = build_session_opts(params)

    case Runtime.start_session(opts) do
      {:ok, session_id, _pid} -> {:ok, %{session_id: session_id}}
      {:error, reason} -> {:error, {:internal, reason}}
    end
  end

  defp call_method("session.stop", %{"session_id" => id}) do
    wrap_ok_error(Runtime.stop_session(id))
  end

  defp call_method("session.stop", _params) do
    {:error, {:invalid_params, "missing required param: session_id"}}
  end

  defp call_method("session.prompt", %{"session_id" => id, "prompt" => prompt}) do
    wrap_ok_error(Runtime.send_prompt(id, prompt))
  end

  defp call_method("session.prompt", _params) do
    {:error, {:invalid_params, "missing required params: session_id, prompt"}}
  end

  defp call_method("session.abort", %{"session_id" => id}) do
    wrap_ok_error(Runtime.abort(id))
  end

  defp call_method("session.abort", _params) do
    {:error, {:invalid_params, "missing required param: session_id"}}
  end

  defp call_method("session.list", _params) do
    {:ok, Runtime.describe_sessions()}
  end

  defp call_method("tool.execute", %{"name" => name, "args" => args}) when is_map(args) do
    case Runtime.execute_tool(name, args) do
      {:ok, result} -> {:ok, %{result: result}}
      {:error, reason} -> {:error, {:internal, reason}}
      {:needs_approval, _spec, _args} -> {:error, {:approval_required, "tool requires approval"}}
    end
  end

  defp call_method("tool.execute", _params) do
    {:error, {:invalid_params, "missing required params: name, args"}}
  end

  defp call_method("tool.list", _params) do
    {:ok, Runtime.describe_tools()}
  end

  defp call_method(method, _params) do
    {:error, {:method_not_found, method}}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec encode_result(term(), {:ok, term()} | {:error, {atom(), term()}}) ::
          {:ok, String.t()} | {:error, String.t()}
  defp encode_result(id, {:ok, result}) do
    {:ok, JSON.encode!(%{jsonrpc: "2.0", id: id, result: result})}
  end

  defp encode_result(id, {:error, {:method_not_found, method}}) do
    {:error, encode_error(id, -32_601, "Method not found: #{method}")}
  end

  defp encode_result(id, {:error, {:invalid_params, message}}) do
    {:error, encode_error(id, -32_602, message)}
  end

  defp encode_result(id, {:error, {:approval_required, message}}) do
    {:error, encode_error(id, -32_603, message)}
  end

  defp encode_result(id, {:error, {:internal, reason}}) do
    {:error, encode_error(id, -32_603, "Internal error: #{inspect(reason)}")}
  end

  @spec encode_error(term(), integer(), String.t()) :: String.t()
  defp encode_error(id, code, message) do
    JSON.encode!(%{
      jsonrpc: "2.0",
      id: id,
      error: %{code: code, message: message}
    })
  end

  @spec build_session_opts(map()) :: keyword()
  defp build_session_opts(params) do
    opts = []
    opts = if params["model"], do: [{:model, params["model"]} | opts], else: opts
    opts = if params["provider"], do: [{:provider, params["provider"]} | opts], else: opts
    opts = if params["changeset"], do: [{:changeset, params["changeset"]} | opts], else: opts
    opts
  end

  @spec wrap_ok_error(:ok | {:error, term()}) :: {:ok, term()} | {:error, {atom(), term()}}
  defp wrap_ok_error(:ok), do: {:ok, %{status: "ok"}}
  defp wrap_ok_error({:error, reason}), do: {:error, {:internal, reason}}
end
