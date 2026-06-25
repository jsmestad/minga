defmodule MingaAgent.Hooks.CommandRunner do
  @moduledoc """
  Executes shell-backed agent hooks through the `minga-hook-runner` helper.

  The helper runs `/bin/sh -c` in a dedicated POSIX process group, feeds the hook payload on stdin, discards stdout, captures bounded stderr, and enforces each hook's timeout. This module owns payload encoding and maps the helper's structured JSON result into `MingaAgent.Hooks.Result`.
  """

  alias MingaAgent.Hooks.CommandRunner.HelperBackend
  alias MingaAgent.Hooks.CommandRunner.PortHelperBackend
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  @helper_name "minga-hook-runner"
  @guard_timeout_ms 1_000
  @helper_stdout_limit 1_048_576

  @typedoc "Options used by tests to inject helper behavior."
  @type run_opts :: [
          helper_path: String.t(),
          helper_backend: module(),
          helper_backend_opts: keyword(),
          clock: (-> integer()),
          guard_timeout_ms: non_neg_integer()
        ]

  @doc "Runs a shell hook with any JSON-encodable payload map."
  @spec run(Hook.t(), map()) :: Result.t()
  def run(%Hook{} = hook, payload_map) when is_map(payload_map) do
    run(hook, payload_map, [])
  end

  @spec run(Hook.t(), map(), run_opts()) :: Result.t()
  def run(%Hook{} = hook, payload_map, opts) when is_map(payload_map) and is_list(opts) do
    with {:ok, payload_json} <- encode_map(payload_map),
         {:ok, helper_path} <- helper_path(opts) do
      run_helper(hook, helper_path, payload_json, opts)
    else
      {:error, reason} -> payload_preparation_veto(hook, reason)
    end
  end

  @doc "Runs a `PreToolUse` shell hook for a payload."
  @spec run_pre_tool_use(Hook.t(), PreToolUsePayload.t()) :: Result.t()
  def run_pre_tool_use(%Hook{} = hook, %PreToolUsePayload{} = payload) do
    run(hook, PreToolUsePayload.to_map(payload))
  end

  @spec run_pre_tool_use(Hook.t(), PreToolUsePayload.t(), run_opts()) :: Result.t()
  def run_pre_tool_use(%Hook{} = hook, %PreToolUsePayload{} = payload, opts) when is_list(opts) do
    run(hook, PreToolUsePayload.to_map(payload), opts)
  end

  @spec encode_map(map()) :: {:ok, String.t()} | {:error, term()}
  defp encode_map(payload_map) do
    {:ok, JSON.encode!(payload_map)}
  rescue
    e -> {:error, safe_encode_reason(e)}
  catch
    kind, _reason -> {:error, {:encode_failed, kind}}
  end

  @spec payload_preparation_veto(Hook.t(), term()) :: Result.t()
  defp payload_preparation_veto(hook, reason) do
    Result.veto(
      hook,
      "failed to prepare hook payload: #{format_prepare_reason(reason)}",
      {:failed_to_start, reason}
    )
  end

  @spec safe_encode_reason(Exception.t()) :: {:encode_failed, module()}
  defp safe_encode_reason(%Protocol.UndefinedError{protocol: protocol}) do
    {:encode_failed, protocol}
  end

  defp safe_encode_reason(%{__struct__: module}) when is_atom(module) do
    {:encode_failed, module}
  end

  @spec format_prepare_reason(term()) :: String.t()
  defp format_prepare_reason({:encode_failed, reason}) do
    "could not JSON encode payload with #{inspect(reason)}"
  end

  defp format_prepare_reason(reason), do: inspect(reason)

  @spec helper_path(run_opts()) :: {:ok, String.t()} | {:error, term()}
  defp helper_path(opts) do
    case Keyword.get(opts, :helper_path) do
      nil -> discover_helper_path()
      path when is_binary(path) -> {:ok, path}
      other -> {:error, {:invalid_helper_path, other}}
    end
  end

  @spec discover_helper_path() :: {:ok, String.t()} | {:error, term()}
  defp discover_helper_path do
    candidates = [
      Path.join(:code.priv_dir(:minga), @helper_name),
      Path.join([File.cwd!(), "priv", @helper_name]),
      Path.join([File.cwd!(), "zig", "zig-out", "bin", @helper_name])
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> {:error, {:helper_not_found, candidates}}
      path -> {:ok, path}
    end
  end

  @spec run_helper(Hook.t(), String.t(), String.t(), run_opts()) :: Result.t()
  defp run_helper(%Hook{} = hook, helper_path, payload_json, opts) do
    backend = helper_backend(opts)
    backend_opts = Keyword.get(opts, :helper_backend_opts, [])
    clock = Keyword.get(opts, :clock, &monotonic_now_ms/0)
    guard_timeout_ms = Keyword.get(opts, :guard_timeout_ms, @guard_timeout_ms)
    args = helper_args(hook, payload_json)

    case backend.start(helper_path, args, payload_json, backend_opts) do
      {:ok, handle} ->
        guard_deadline_ms = clock.() + hook.timeout_ms + guard_timeout_ms

        collect_helper_result(
          backend,
          handle,
          hook,
          "",
          guard_deadline_ms,
          clock,
          guard_timeout_ms
        )

      {:error, reason} ->
        helper_start_error(hook, reason)
    end
  rescue
    e -> helper_start_error(hook, e)
  catch
    kind, reason -> helper_start_error(hook, {kind, reason})
  end

  @spec helper_backend(run_opts()) :: module()
  defp helper_backend(opts) do
    Keyword.get(opts, :helper_backend, PortHelperBackend)
  end

  @spec helper_args(Hook.t(), String.t()) :: [String.t()]
  defp helper_args(hook, payload_json) do
    [
      Integer.to_string(hook.timeout_ms),
      Integer.to_string(byte_size(payload_json)),
      hook.command
    ]
  end

  @spec helper_start_error(Hook.t(), term()) :: Result.t()
  defp helper_start_error(hook, %_{} = exception) do
    Result.veto(
      hook,
      "failed to start hook runner: #{Exception.message(exception)}",
      {:failed_to_start, exception}
    )
  end

  defp helper_start_error(hook, {kind, reason}) when is_atom(kind) do
    Result.veto(
      hook,
      "failed to start hook runner: #{inspect(kind)} #{inspect(reason)}",
      {:failed_to_start, {kind, reason}}
    )
  end

  defp helper_start_error(hook, reason) do
    Result.veto(
      hook,
      "failed to start hook runner: #{inspect(reason)}",
      {:failed_to_start, reason}
    )
  end

  @spec collect_helper_result(
          module(),
          HelperBackend.handle(),
          Hook.t(),
          String.t(),
          integer(),
          (-> integer()),
          non_neg_integer()
        ) :: Result.t()
  defp collect_helper_result(
         backend,
         handle,
         hook,
         stdout,
         guard_deadline_ms,
         clock,
         guard_timeout_ms
       ) do
    remaining_ms = guard_deadline_ms - clock.()

    if remaining_ms <= 0 do
      helper_timeout(backend, handle, hook, guard_timeout_ms)
    else
      case backend.next_event(handle, remaining_ms) do
        {:data, data, next_handle} ->
          next_stdout = append_helper_stdout(stdout, data)

          collect_helper_result(
            backend,
            next_handle,
            hook,
            next_stdout,
            guard_deadline_ms,
            clock,
            guard_timeout_ms
          )

        {:exit_status, 0, _next_handle} ->
          decode_helper_result(hook, stdout)

        {:exit_status, status, _next_handle} ->
          Result.veto(
            hook,
            "hook runner exited with status #{status}",
            {:failed_to_start, {:helper_exit, status}}
          )

        :timeout ->
          helper_timeout(backend, handle, hook, guard_timeout_ms)
      end
    end
  end

  @spec append_helper_stdout(String.t(), binary()) :: String.t()
  defp append_helper_stdout(stdout, _data) when byte_size(stdout) >= @helper_stdout_limit,
    do: stdout

  defp append_helper_stdout(stdout, data) do
    remaining = @helper_stdout_limit - byte_size(stdout)

    if byte_size(data) <= remaining do
      stdout <> data
    else
      stdout <> binary_part(data, 0, remaining)
    end
  end

  @spec helper_timeout(module(), HelperBackend.handle(), Hook.t(), non_neg_integer()) ::
          Result.t()
  defp helper_timeout(backend, handle, hook, guard_timeout_ms) do
    backend.stop(handle)

    Result.veto(
      hook,
      "hook runner timed out after #{hook.timeout_ms + guard_timeout_ms}ms",
      {:failed_to_start, :helper_timeout}
    )
  end

  @spec monotonic_now_ms() :: integer()
  defp monotonic_now_ms, do: System.monotonic_time(:millisecond)

  @spec decode_helper_result(Hook.t(), String.t()) :: Result.t()
  defp decode_helper_result(hook, stdout) do
    case JSON.decode(stdout) do
      {:ok, %{"status" => "allow"}} ->
        Result.allow(hook)

      {:ok, %{"status" => "veto", "reason" => %{"type" => "exit", "status" => status}} = result}
      when is_integer(status) and status >= 0 ->
        Result.veto(hook, result_stderr(result), {:exit, status})

      {:ok, %{"status" => "veto", "reason" => %{"type" => "timeout"}} = result} ->
        Result.veto(hook, timeout_stderr(hook, result_stderr(result)), :timeout)

      {:ok, %{"status" => "error", "message" => message}} when is_binary(message) ->
        Result.veto(hook, "hook runner failed: #{message}", {:failed_to_start, :helper_error})

      {:ok, _other} ->
        malformed_result(hook)

      {:error, _reason} ->
        malformed_result(hook)
    end
  end

  @spec result_stderr(map()) :: String.t()
  defp result_stderr(%{"stderr" => stderr}) when is_binary(stderr), do: stderr
  defp result_stderr(_result), do: ""

  @spec timeout_stderr(Hook.t(), String.t()) :: String.t()
  defp timeout_stderr(hook, stderr) do
    label = Hook.event_label(hook.event)
    message = "#{label} hook timed out after #{hook.timeout_ms}ms and was killed"

    case String.trim(stderr) do
      "" -> message
      _non_empty -> stderr <> "\n" <> message
    end
  end

  @spec malformed_result(Hook.t()) :: Result.t()
  defp malformed_result(hook) do
    Result.veto(
      hook,
      "malformed hook runner result",
      {:failed_to_start, :malformed_helper_result}
    )
  end
end
