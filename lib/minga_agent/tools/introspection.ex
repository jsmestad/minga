defmodule MingaAgent.Tools.Introspection do
  @moduledoc """
  Agent tools for runtime self-description.

  Lets an LLM agent discover what tools are available and what the
  runtime can do. Both tools are read-only (`:auto` approval, no
  side effects) and return formatted text suitable for LLM consumption.
  """

  alias MingaAgent.Introspection

  @doc """
  Returns a human-readable summary of the runtime's capabilities.

  Includes version, tool count by category, active session count,
  and enabled features.
  """
  @spec describe_runtime(map()) :: {:ok, String.t()}
  def describe_runtime(_args) do
    caps = Introspection.capabilities()
    {:ok, format_capabilities(caps)}
  end

  @doc """
  Returns a human-readable list of all registered tools.

  Each tool is listed with its name, category, and description.
  """
  @spec describe_tools(map()) :: {:ok, String.t()}
  def describe_tools(_args) do
    tools = Introspection.describe_tools()
    {:ok, format_tools(tools)}
  end

  # ── Formatting ──────────────────────────────────────────────────────────────

  @spec format_capabilities(Introspection.capabilities_manifest()) :: String.t()
  defp format_capabilities(caps) do
    categories =
      case caps.tool_categories do
        [] -> "none"
        cats -> Enum.map_join(cats, ", ", &to_string/1)
      end

    features = Enum.map_join(caps.features, ", ", &to_string/1)

    """
    Minga Runtime v#{caps.version}
    Tools: #{caps.tool_count} (#{categories})
    Sessions: #{caps.session_count}
    Features: #{features}
    """
    |> String.trim()
  end

  @spec format_tools([Introspection.tool_description()]) :: String.t()
  defp format_tools([]), do: "No tools registered."

  defp format_tools(tools) do
    Enum.map_join(tools, "\n", fn t ->
      desc =
        t.description
        |> String.trim()
        |> String.split("\n", parts: 2)
        |> hd()
        |> String.trim()

      "- #{t.name} [#{t.category}]: #{desc}"
    end)
  end
end
