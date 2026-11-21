defmodule MingaAgent.InferenceRoute.ToolCall do
  @moduledoc """
  One complete tool call. `arguments` is a decoded map. Minga runs the call; a route never does.

  This is a compile-time stub.
  """

  @enforce_keys [:id, :name, :arguments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), name: String.t(), arguments: map()}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {:invalid_tool_call, atom()}}
  def new(_attrs), do: raise("minga_sdk is compile-time only")
end
