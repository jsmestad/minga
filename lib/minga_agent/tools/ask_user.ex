defmodule MingaAgent.Tools.AskUser do
  @moduledoc "Pauses a native turn for a clarification without granting tool permissions."

  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Spec

  @doc "Declares the clarification tool. Only an admitted Session invocation can ask."
  @spec spec() :: Spec.t()
  def spec do
    Spec.new!(
      name: "ask_user",
      description:
        "Ask the user a clarification question. Optionally provide short choices. The user can select a choice, type an answer, or cancel without answering.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_096},
          "choices" => %{
            "type" => "array",
            "maxItems" => 8,
            "uniqueItems" => true,
            "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 256}
          }
        },
        "required" => ["prompt"],
        "additionalProperties" => false
      },
      source: :builtin,
      category: :agent,
      approval_level: :auto,
      capabilities: [],
      context_requirements: [:tool_context],
      build: fn context -> fn _arguments -> request(context) end end
    )
  end

  @spec request(Context.t()) :: {:ok, String.t()} | {:error, term()}
  defp request(%Context{session_invocation: {session, invocation}}) do
    case GenServer.call(session, {:question_invocation, invocation}, :infinity) do
      {:ok, {:answered, answer}} -> {:ok, JSON.encode!(%{status: "answered", answer: answer})}
      {:ok, :cancelled} -> {:ok, JSON.encode!(%{status: "cancelled"})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(_context), do: {:error, :session_invocation_required}
end
