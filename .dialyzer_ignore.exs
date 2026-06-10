# Dialyzer warnings to ignore.
[
  # llm_db 2026.4.8 / req_llm 1.11.0: Dialyzer can't resolve LLMDB.models/0 or
  # LLMDB.Model.t/0 across dep boundaries (persistent_term-backed Store). Works at runtime.
  {"lib/minga_agent/cost_calculator.ex", :unknown_function},
  {"lib/minga_agent/model_catalog.ex", :unknown_function},
  {"lib/req_llm/stream_response.ex", :unknown_type}
]
