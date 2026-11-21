defmodule MingaAgent.InferenceRoute.ToolCall do
  @moduledoc "One complete tool call: Minga runs it through its own executor and approval flow."

  @enforce_keys [:id, :name, :arguments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), name: String.t(), arguments: map()}

  @doc "Builds a tool call. `arguments` must already be a decoded map."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {:invalid_tool_call, atom()}}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{id: id, name: name, arguments: arguments})
      when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(arguments),
      do: {:ok, %__MODULE__{id: id, name: name, arguments: arguments}}

  def new(%{arguments: arguments}) when not is_map(arguments),
    do: {:error, {:invalid_tool_call, :arguments}}

  def new(_attrs), do: {:error, {:invalid_tool_call, :fields}}
end
