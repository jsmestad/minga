defmodule MingaAgent.ConfigTest do
  @moduledoc "Tests for the centralized Agent.Config module."
  use ExUnit.Case, async: true

  alias Minga.Config.Options
  alias MingaAgent.Config

  describe "resolve/0" do
    test "returns a Config struct with all fields populated" do
      config = Config.resolve()
      assert %Config{} = config

      assert provider_qualified_model?(config.model) or
               config.model == Config.unconfigured_model()

      assert is_integer(config.max_tokens)
      assert is_integer(config.max_turns)
      assert is_integer(config.max_retries)
      assert is_boolean(config.prompt_cache)
      assert is_boolean(config.notifications)
      assert is_list(config.destructive_tools)
      assert is_list(config.agent_hooks)
      assert is_list(config.notify_on)
    end

    test "model defaults to a credential-backed model or the unconfigured sentinel" do
      config = Config.resolve()

      assert provider_qualified_model?(config.model) or
               config.model == Config.unconfigured_model()
    end

    test "struct defaults match Options defaults" do
      config = Config.resolve()
      assert config.max_tokens == 16_384
      assert config.max_turns == 100
      assert config.max_retries == 3
      assert config.max_cost == nil
      assert config.tool_approval == :destructive

      assert config.destructive_tools ==
               ~w(write_file edit_file multi_edit_file apply_diff delete_file shell git_stage git_commit rename)

      assert config.agent_hooks == []
      assert config.prompt_cache == true
      assert config.compaction_threshold == 0.80
      assert config.compaction_keep_recent == 6
      assert config.approval_timeout_ms == 300_000
      assert config.subagent_timeout_ms == 300_000
      assert config.shell_debounce_ms == 200
      assert config.max_file_size == 256 * 1024
      assert config.max_image_size == 5 * 1024 * 1024
      assert config.max_mention_candidates == 10
      assert config.memory_max_tokens == 4_000
      assert config.notify_debounce_ms == 5_000
      assert config.panel_split == 65
      assert config.diff_size_threshold == 1_048_576
      assert config.session_retention_days == 30
      assert config.save_debounce_ms == 500
      assert config.mcp_servers == []
    end
  end

  describe "MCP config" do
    test "defaults to an empty list" do
      config = Config.resolve()
      assert config.mcp_servers == []
    end

    test "keeps raw server maps so provider startup can report config errors" do
      server = start_supervised!({Options, name: nil})
      Process.put(:minga_config_options, server)

      raw_config = [%{name: "local"}]
      assert {:ok, ^raw_config} = Options.set(server, :agent_mcp_servers, raw_config)
      assert Config.resolve().mcp_servers == raw_config
    end
  end

  describe "default_model/0" do
    test "returns a usable model or the unconfigured sentinel" do
      model = Config.default_model()
      assert is_binary(model)
      refute model == ""
    end
  end

  describe "model spec parsing" do
    test "supports provider:model and model@provider forms" do
      assert Config.split_model_spec("anthropic:claude-sonnet-4") ==
               {"claude-sonnet-4", "anthropic"}

      assert Config.split_model_spec("claude-sonnet-4@anthropic") ==
               {"claude-sonnet-4", "anthropic"}

      assert Config.strip_provider_prefix("claude-sonnet-4@anthropic") ==
               "claude-sonnet-4"

      assert Config.extract_provider_prefix("claude-sonnet-4@anthropic") == "anthropic"
    end
  end

  describe "normalize_hooks/1" do
    test "normalizes PreToolUse hooks from config maps" do
      assert [hook] =
               Config.normalize_hooks([
                 %{event: "PreToolUse", tool: "shell", command: "echo policy >&2"}
               ])

      assert hook.event == :pre_tool_use
      assert hook.tool_pattern == "shell"
      assert hook.command == "echo policy >&2"
      assert hook.timeout_ms == 30_000
    end
  end

  defp provider_qualified_model?(model) when is_binary(model) do
    String.contains?(model, ":") or String.contains?(model, "@")
  end
end
