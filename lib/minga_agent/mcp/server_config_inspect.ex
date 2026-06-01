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
        env: Redaction.redact_env(config.env)
    }

    concat([
      "#MingaAgent.MCP.ServerConfig<",
      to_doc(Map.from_struct(redacted), opts),
      ">"
    ])
  end
end
