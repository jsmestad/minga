defmodule Minga.Platform.Stub do
  @moduledoc """
  Test stub for `Minga.Platform`. Returns `:ok` by default.

  Error-path tests can configure a caller-local result. Jobs started by an
  isolated scheduler inherit its test configuration through Task callers.
  """

  @type response :: Minga.Platform.trash_result() | {:wait, pid(), Minga.Platform.trash_result()}

  @key :platform_stub_trash_result

  @spec trash(String.t()) :: Minga.Platform.trash_result()
  def trash(path) do
    case Process.get(@key) || task_caller_result() do
      nil ->
        :ok

      {:wait, test, result} ->
        send(test, {:trash_started, self(), path})

        receive do
          :finish_trash -> result
        after
          3_000 -> {:error, "test did not release trash worker"}
        end

      result ->
        result
    end
  end

  @spec task_caller_result() :: response() | nil
  defp task_caller_result do
    Enum.find_value(Process.get(:"$callers", []), fn caller ->
      case Process.info(caller, :dictionary) do
        {:dictionary, values} -> Keyword.get(values, @key)
        nil -> nil
      end
    end)
  end

  @doc """
  Configures the return value for `trash/1` in the current test process.

  ## Examples

      Minga.Platform.Stub.set_trash_result({:error, "no trash support"})
  """
  @spec set_trash_result(response()) :: :ok
  def set_trash_result(result) do
    Process.put(@key, result)
    :ok
  end
end
