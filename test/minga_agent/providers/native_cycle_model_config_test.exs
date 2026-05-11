defmodule MingaAgent.Providers.NativeCycleModelConfigTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Providers.Native

  @moduletag :tmp_dir
  @moduletag :heavy

  defp start_provider(opts) do
    defaults = [
      subscriber: self(),
      model: "anthropic:claude-sonnet-4-20250514",
      config: %AgentConfig{},
      project_root: opts[:tmp_dir] || System.tmp_dir!(),
      tools: [],
      skip_api_key_env: true
    ]

    defaults
    |> Keyword.merge(opts)
    |> Native.start_link()
  end

  describe "cycle_model/1 with configured model list" do
    test "returns the active thinking level and only parses valid thinking suffixes", %{
      tmp_dir: dir
    } do
      config = %AgentConfig{
        models: [
          "anthropic:claude-sonnet-4-20250514",
          "bedrock:anthropic.claude-3-sonnet-20240229-v1:0:medium",
          "openai:o3:turbo"
        ]
      }

      {:ok, pid} = start_provider(tmp_dir: dir, config: config, thinking_level: "low")

      assert {:ok,
              %{
                "model" => "bedrock:anthropic.claude-3-sonnet-20240229-v1:0",
                "thinking_level" => "medium"
              }} = Native.cycle_model(pid)

      assert {:ok, state} = Native.get_state(pid)
      assert state.model.id == "bedrock:anthropic.claude-3-sonnet-20240229-v1:0"
      assert state.thinking_level == "medium"

      assert {:ok, %{"model" => "openai:o3:turbo", "thinking_level" => "medium"}} =
               Native.cycle_model(pid)
    end
  end
end
