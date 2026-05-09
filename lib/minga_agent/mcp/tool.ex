defmodule MingaAgent.MCP.Tool do
  @moduledoc """
  MCP tool metadata with both the original server name and Minga-safe name.

  MCP servers may expose names that are not safe for LLM provider tool-name
  restrictions. Native provider requests use `safe_name`; MCP calls use the
  original `name` captured in the tool callback.
  """

  @enforce_keys [:server_name, :name, :safe_name, :description, :input_schema]
  defstruct [:server_name, :name, :safe_name, :description, :input_schema]

  @typedoc "Tool advertised by an MCP server."
  @type t :: %__MODULE__{
          server_name: String.t(),
          name: String.t(),
          safe_name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @doc "Builds tool structs from a MCP `tools/list` result."
  @spec from_list(String.t(), [map()]) :: [t()]
  def from_list(server_name, tools) when is_binary(server_name) and is_list(tools) do
    {result, _seen} =
      Enum.reduce(tools, {[], MapSet.new()}, fn tool, {acc, seen} ->
        case from_map(server_name, tool, seen) do
          {:ok, mcp_tool, seen} -> {[mcp_tool | acc], seen}
          :skip -> {acc, seen}
        end
      end)

    Enum.reverse(result)
  end

  @doc "Returns the safe provider-facing name for a MCP tool."
  @spec safe_name(String.t(), String.t()) :: String.t()
  def safe_name(server_name, tool_name) do
    "mcp_#{sanitize(server_name)}__#{sanitize(tool_name)}"
  end

  @spec from_map(String.t(), map(), MapSet.t(String.t())) ::
          {:ok, t(), MapSet.t(String.t())} | :skip
  defp from_map(server_name, %{"name" => name} = tool, seen) when is_binary(name) do
    base_safe_name = safe_name(server_name, name)
    safe_name = unique_name(base_safe_name, seen)
    seen = MapSet.put(seen, safe_name)

    {:ok,
     %__MODULE__{
       server_name: server_name,
       name: name,
       safe_name: safe_name,
       description: description(tool, name),
       input_schema: input_schema(tool)
     }, seen}
  end

  defp from_map(_server_name, _tool, _seen), do: :skip

  @spec description(map(), String.t()) :: String.t()
  defp description(tool, name) do
    case Map.get(tool, "description") do
      desc when is_binary(desc) and desc != "" -> desc
      _ -> "MCP tool #{name}"
    end
  end

  @spec input_schema(map()) :: map()
  defp input_schema(tool) do
    case Map.get(tool, "inputSchema") || Map.get(tool, "input_schema") do
      schema when is_map(schema) -> schema
      _ -> %{"type" => "object", "properties" => %{}}
    end
  end

  @spec unique_name(String.t(), MapSet.t(String.t())) :: String.t()
  defp unique_name(name, seen) do
    if MapSet.member?(seen, name) do
      unique_name(name, seen, 2)
    else
      name
    end
  end

  @spec unique_name(String.t(), MapSet.t(String.t()), pos_integer()) :: String.t()
  defp unique_name(name, seen, index) do
    candidate = "#{name}_#{index}"

    if MapSet.member?(seen, candidate) do
      unique_name(name, seen, index + 1)
    else
      candidate
    end
  end

  @spec sanitize(String.t()) :: String.t()
  defp sanitize(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> non_empty_safe_name()
  end

  @spec non_empty_safe_name(String.t()) :: String.t()
  defp non_empty_safe_name(""), do: "server"
  defp non_empty_safe_name(value), do: value
end
