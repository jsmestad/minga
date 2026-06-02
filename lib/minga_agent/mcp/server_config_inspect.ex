defimpl Inspect, for: MingaAgent.MCP.ServerConfig do
  @moduledoc false

  import Inspect.Algebra

  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.Redaction

  @spec inspect(ServerConfig.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(%ServerConfig{} = config, opts) do
    redacted = %{
      config
      | args: Redaction.redact_args(config.args),
        env: redact_env(config.env)
    }

    concat([
      "#MingaAgent.MCP.ServerConfig<",
      to_doc(Map.from_struct(redacted), opts),
      ">"
    ])
  end

  @spec redact_env(term()) :: term()
  defp redact_env(env) when is_map(env), do: Redaction.redact_env(env)
  defp redact_env(env), do: Redaction.redact_term(env)
end
