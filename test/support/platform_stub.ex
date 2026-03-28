defmodule Minga.Platform.Stub do
  @moduledoc """
  Test stub for `Minga.Platform`. Returns `:ok` by default.

  For error-path tests, use `set_trash_result/1` to configure the return value
  for the current test process. Uses the process dictionary for isolation
  between concurrent tests.
  """

  @spec trash(String.t()) :: :ok | {:error, String.t()}
  def trash(_path) do
    case Process.get(:platform_stub_trash_result) do
      nil -> :ok
      result -> result
    end
  end

  @doc """
  Configures the return value for `trash/1` in the current test process.

  ## Examples

      Minga.Platform.Stub.set_trash_result({:error, "no trash support"})
  """
  @spec set_trash_result(:ok | {:error, String.t()}) :: :ok
  def set_trash_result(result) do
    Process.put(:platform_stub_trash_result, result)
    :ok
  end
end
