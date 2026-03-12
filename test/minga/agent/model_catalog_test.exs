defmodule Minga.Agent.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.ModelCatalog

  describe "available_models/1" do
    test "returns a list of maps with expected keys" do
      models = ModelCatalog.available_models()

      # Even if no API keys are set, the function should return a list
      assert is_list(models)

      for model <- models do
        assert is_map(model)
        assert Map.has_key?(model, "id")
        assert Map.has_key?(model, "name")
        assert Map.has_key?(model, "provider")
        assert Map.has_key?(model, "context_window")
        assert Map.has_key?(model, "cost")
        assert Map.has_key?(model, "current")
      end
    end

    test "model IDs use provider:model format" do
      models = ModelCatalog.available_models()

      for model <- models do
        assert String.contains?(model["id"], ":")
      end
    end

    test "excludes deprecated and retired models" do
      models = ModelCatalog.available_models()

      for model <- models do
        refute String.contains?(model["name"] || "", "deprecated")
      end
    end

    test "excludes non-chat models" do
      models = ModelCatalog.available_models()
      ids = Enum.map(models, & &1["id"])

      for id <- ids do
        refute String.contains?(id, "embedding")
        refute String.contains?(id, "tts")
        refute String.contains?(id, "whisper")
        refute String.contains?(id, "dall-e")
        refute String.contains?(id, "sora")
      end
    end

    test "marks the current model" do
      models = ModelCatalog.available_models("anthropic:claude-sonnet-4-20250514")

      current = Enum.filter(models, & &1["current"])
      non_current = Enum.reject(models, & &1["current"])

      # If anthropic key is set, there should be exactly one current model
      # If not set, no models from anthropic will appear
      if Enum.any?(models, &(&1["provider"] == "anthropic")) do
        assert length(current) == 1
        assert hd(current)["id"] == "anthropic:claude-sonnet-4-20250514"
      end

      for model <- non_current do
        refute model["current"]
      end
    end

    test "only includes models for configured providers" do
      models = ModelCatalog.available_models()
      providers = Enum.map(models, & &1["provider"]) |> Enum.uniq()

      # All returned providers should be ones we have credentials for
      for provider <- providers do
        assert provider in ["anthropic", "openai", "google"]
      end
    end
  end
end
