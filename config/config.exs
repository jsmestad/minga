import Config

# Minga can run several agent and subagent streams concurrently. ReqLLM 1.16 exposes Finch stream pool controls, so keep the provider-compatible HTTP/1 transport while allowing larger bursts to queue without checkout failures.
config :req_llm,
  stream_pool_timeout: 300_000,
  stream_pool_protocols: [:http1],
  stream_pool_size: 1,
  stream_pool_count: 32,
  thinking_timeout: 600_000

# Import environment-specific config at the bottom so it can
# override values set above.
import_config "#{config_env()}.exs"
