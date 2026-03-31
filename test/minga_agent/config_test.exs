defmodule MingaAgent.ConfigTest do
  @moduledoc "Tests for the centralized Agent.Config module."
  use ExUnit.Case, async: true

  alias MingaAgent.Config

  describe "resolve/0" do
    test "returns a Config struct with all fields populated" do
      config = Config.resolve()
      assert %Config{} = config
      assert is_binary(config.model)
      assert is_integer(config.max_tokens)
      assert is_integer(config.max_turns)
      assert is_integer(config.max_retries)
      assert is_boolean(config.prompt_cache)
      assert is_boolean(config.notifications)
      assert is_list(config.destructive_tools)
      assert is_list(config.notify_on)
    end

    test "model defaults to Sonnet when Options has nil" do
      config = Config.resolve()
      assert config.model =~ "claude"
    end

    test "struct defaults match Options defaults" do
      config = Config.resolve()
      assert config.max_tokens == 16_384
      assert config.max_turns == 100
      assert config.max_retries == 3
      assert config.max_cost == nil
      assert config.tool_approval == :destructive
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
    end
  end

  describe "default_model/0" do
    test "returns the Sonnet model string" do
      assert Config.default_model() =~ "anthropic:claude"
    end
  end
end
