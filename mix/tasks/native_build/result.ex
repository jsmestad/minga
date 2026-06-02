defmodule Mix.Tasks.Native.Build.Result do
  @moduledoc false

  @spec raise_on_error({:ok, []} | {:error, []}, String.t()) :: :ok
  def raise_on_error({:ok, []}, _message), do: :ok
  def raise_on_error({:error, []}, message), do: Mix.raise(message)
end
