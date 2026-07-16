defmodule Minga.Extension.CallbackInvoker do
  @moduledoc """
  The runtime trust boundary for extension-owned callbacks.

  Ordinary invocation admits active source-owned code before entering the
  callback. Unload invocation is a distinct token-scoped operation for a source
  that is already quiescing. Both entry points normalize exceptions, throws, and
  exits without translating failure into a successful decline or no-op.

  Domain adapters remain responsible for validating successful return values.
  They use `invalid_return/4` so malformed extension values share this boundary's
  observable failure type while core callbacks continue to run directly.
  """

  alias Minga.Extension.CodeLease
  alias Minga.Extension.InvocationContext

  @typedoc "An extension source accepted by the runtime callback boundary."
  @type source :: {:extension, atom()}

  @typedoc "The callback operation being performed, used in diagnostics."
  @type semantics :: atom()

  @typedoc "A contained extension callback failure."
  @type failure ::
          {:source_unavailable, source(), module(), atom(), term()}
          | {:callback_failed, source(), module(), atom(), :exception | :exit | :throw, term()}
          | {:invalid_return, source(), module(), atom(), term()}

  @typedoc "A successful callback value or an explicit extension failure."
  @type result(value) :: {:ok, value} | {:error, failure()}

  @doc "Invokes an active extension callback after source-aware admission."
  @spec invoke(source(), module(), atom(), [term()], semantics(), GenServer.server()) ::
          result(term())
  def invoke(
        {:extension, name} = source,
        module,
        function,
        args,
        semantics,
        admission \\ CodeLease
      )
      when is_atom(name) and is_atom(module) and is_atom(function) and is_list(args) and
             is_atom(semantics) do
    case CodeLease.admit_callback(source, module, semantics, server: admission) do
      {:ok, lease} -> invoke_admitted(source, module, function, args, semantics, lease)
      {:error, reason} -> unavailable(source, module, function, reason)
    end
  end

  @doc "Invokes a callback owned by a quiescing source using unload authority."
  @spec invoke_unload(
          source(),
          CodeLease.unload_token(),
          module(),
          atom(),
          [term()],
          semantics(),
          GenServer.server()
        ) :: result(term())
  def invoke_unload(
        {:extension, name} = source,
        token,
        module,
        function,
        args,
        semantics,
        admission \\ CodeLease
      )
      when is_atom(name) and is_reference(token) and is_atom(module) and is_atom(function) and
             is_list(args) and is_atom(semantics) do
    case CodeLease.admit_unload_callback(token, module, semantics, server: admission) do
      {:ok, %{source: ^source} = lease} ->
        invoke_admitted(source, module, function, args, semantics, lease)

      {:ok, lease} ->
        reject_wrong_unload_source(source, module, function, lease)

      {:error, reason} ->
        unavailable(source, module, function, reason)
    end
  end

  @doc "Builds and reports a malformed successful extension return."
  @spec invalid_return(source(), module(), atom(), term()) :: failure()
  def invalid_return({:extension, name} = source, module, function, returned)
      when is_atom(name) and is_atom(module) and is_atom(function) do
    failure = {:invalid_return, source, module, function, invalid_return_summary(returned)}
    report_failure(failure)
    failure
  end

  @spec invoke_admitted(
          source(),
          module(),
          atom(),
          [term()],
          semantics(),
          CodeLease.t()
        ) :: result(term())
  defp invoke_admitted(source, module, function, args, semantics, lease) do
    case callback_available(module, function, length(args)) do
      :ok ->
        {:ok,
         InvocationContext.with_source(source, fn ->
           apply(module, function, args)
         end)}

      {:error, reason} ->
        unavailable(source, module, function, reason)
    end
  rescue
    exception ->
      callback_failure(
        source,
        module,
        function,
        :exception,
        exception,
        semantics,
        __STACKTRACE__
      )
  catch
    :exit, reason ->
      callback_failure(source, module, function, :exit, reason, semantics, __STACKTRACE__)

    :throw, reason ->
      callback_failure(source, module, function, :throw, reason, semantics, __STACKTRACE__)
  after
    CodeLease.release(lease)
  end

  @spec callback_available(module(), atom(), non_neg_integer()) :: :ok | {:error, term()}
  defp callback_available(module, function, arity) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> exported_callback(module, function, arity)
      {:error, reason} -> {:error, {:module_unavailable, reason}}
    end
  end

  @spec exported_callback(module(), atom(), non_neg_integer()) :: :ok | {:error, term()}
  defp exported_callback(module, function, arity) do
    if function_exported?(module, function, arity) do
      :ok
    else
      {:error, {:function_unavailable, arity}}
    end
  end

  @spec reject_wrong_unload_source(source(), module(), atom(), CodeLease.t()) :: result(term())
  defp reject_wrong_unload_source(source, module, function, lease) do
    CodeLease.release(lease)
    unavailable(source, module, function, {:unload_source_mismatch, lease.source})
  end

  @spec unavailable(source(), module(), atom(), term()) :: {:error, failure()}
  defp unavailable(source, module, function, reason) do
    failure = {:source_unavailable, source, module, function, reason}
    report_failure(failure)
    {:error, failure}
  end

  @spec callback_failure(
          source(),
          module(),
          atom(),
          :exception | :exit | :throw,
          term(),
          semantics(),
          Exception.stacktrace()
        ) :: {:error, failure()}
  defp callback_failure(source, module, function, kind, reason, semantics, stacktrace) do
    failure = {:callback_failed, source, module, function, kind, reason}
    report_failure(failure, semantics: semantics, stacktrace: stacktrace)
    {:error, failure}
  end

  @spec invalid_return_summary(term()) :: map()
  defp invalid_return_summary(value) when is_tuple(value) do
    tag = if tuple_size(value) > 0 and is_atom(elem(value, 0)), do: elem(value, 0), else: nil
    %{kind: :tuple, size: tuple_size(value), tag: tag}
  end

  defp invalid_return_summary(%module{}), do: %{kind: :struct, module: module}
  defp invalid_return_summary(value) when is_map(value), do: %{kind: :map, size: map_size(value)}
  defp invalid_return_summary(value) when is_list(value), do: %{kind: :list, empty?: value == []}

  defp invalid_return_summary(value) when is_binary(value),
    do: %{kind: :binary, size: byte_size(value)}

  defp invalid_return_summary(value) when is_atom(value), do: %{kind: :atom, value: value}
  defp invalid_return_summary(value) when is_number(value), do: %{kind: :number}
  defp invalid_return_summary(_value), do: %{kind: :other}

  @spec report_failure(failure(), keyword()) :: :ok
  defp report_failure(failure, diagnostic_opts \\ []) do
    semantics = Keyword.get(diagnostic_opts, :semantics)
    stacktrace = Keyword.get(diagnostic_opts, :stacktrace, [])

    diagnostic =
      case stacktrace do
        [] ->
          "Extension callback failed: #{inspect(failure)}"

        [_frame | _rest] ->
          "Extension callback failed semantics=#{inspect(semantics)}: #{inspect(failure)}\n" <>
            Exception.format_stacktrace(stacktrace)
      end

    Minga.Log.warning(:config, diagnostic)
  end
end
