defmodule MingaAgent.Tool.PlanMode do
  @moduledoc """
  Plan-mode guard for agent tool execution.

  Plan mode is a session-level safety state. While active, read-only tools keep working, but destructive tools are refused before their callbacks run.
  """

  alias MingaAgent.Tools

  @typedoc "Tool refusal reason returned to callers."
  @type refusal :: {:plan_mode_refused, String.t()}

  @doc "Returns true when the tool call must be blocked in plan mode."
  @spec blocked?(String.t(), map()) :: boolean()
  def blocked?(name, args) when is_binary(name) and is_map(args) do
    Tools.destructive?(name, args)
  end

  @doc "Returns the user-facing refusal message for a blocked plan-mode tool call."
  @spec refusal_message(String.t()) :: String.t()
  def refusal_message(name) when is_binary(name) do
    "Plan mode is active. Refusing destructive tool #{name}. Use /exec to leave plan mode before running tools that change files, shell state, git state, or LSP edits."
  end

  @doc "Returns the structured refusal tuple for a blocked plan-mode tool call."
  @spec refusal(String.t()) :: refusal()
  def refusal(name) when is_binary(name) do
    {:plan_mode_refused, refusal_message(name)}
  end
end
