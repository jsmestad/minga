defmodule MingaAgent.InferenceRouteSourceGuardTest do
  use ExUnit.Case, async: true

  # Core handles contributed routes only through the generic `{:contributed, _, _}` origin and the registry.
  @allowed [
    "lib/minga_agent/inference_route_registry.ex",
    "lib/minga_agent/providers/native/req_llm_adapter.ex"
  ]

  @patterns [
    {~S|\{:contributed,\s*"|, "a literal route id in a contributed origin"},
    {~S|route_id:\s*"|, "a literal route id"},
    {~S|\bFixtureInferenceRoute\b|, "the fixture route module"},
    {~S|request_provider:\s*:contributed[^}]*model_provider:\s*"|,
     "a literal contributed route owner"}
  ]

  test "no core module matches on a specific contributed route id or module" do
    # Compile each pattern once: regexes stored in module attributes are recompiled on every use.
    patterns =
      Enum.map(@patterns, fn {source, description} -> {Regex.compile!(source), description} end)

    violations =
      for path <- Path.wildcard("lib/**/*.ex"),
          path not in @allowed,
          source = File.read!(path),
          String.contains?(source, ["contributed", "route_id", "FixtureInferenceRoute"]),
          {pattern, description} <- patterns,
          Regex.match?(pattern, source),
          do: "#{path}: #{description}"

    assert violations == []
  end

  test "the route contract, extension API, fixture, and SDK never mention the model library" do
    files =
      Path.wildcard("lib/minga_agent/inference_route*.ex") ++
        Path.wildcard("lib/minga_agent/inference_route/**/*.ex") ++
        Path.wildcard("lib/minga_agent/inference_route_registry/**/*.ex") ++
        ["lib/minga/extension/model_routes.ex", "test/support/fixture_inference_route.ex"] ++
        Path.wildcard("sdk/lib/**/*.ex")

    # The guard must actually see the contract and the SDK.
    assert "lib/minga_agent/inference_route/request.ex" in files
    assert "sdk/lib/minga_agent/inference_route/response.ex" in files

    violations =
      for path <- files,
          source = File.read!(path),
          Regex.match?(~r/\b(ReqLLM|LLMDB)\b/, source),
          do: path

    assert violations == []
  end
end
