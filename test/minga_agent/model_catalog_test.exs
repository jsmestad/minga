defmodule MingaAgent.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelCatalog

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

    test "model IDs are unique after catalog alias normalization" do
      ids = ModelCatalog.available_models() |> Enum.map(& &1["id"])

      assert ids == Enum.uniq(ids)
    end

    test "canonical codex aliases dedupe, filter, and sort deterministically" do
      current_model = "openai_codex:openai/gpt-5.1-codex-max"
      configured_providers = MapSet.new([:openai])

      models = [
        codex_model("gpt-5.3-codex", "GPT-5.3 Codex"),
        codex_model("openai/gpt-5.3-codex", "OpenAI: GPT-5.3 Codex"),
        codex_model("gpt-5.3-codex-xhigh", "GPT-5.3 Codex XHigh"),
        codex_model("gpt-5.2-codex", "GPT-5.2 Codex"),
        codex_model("gpt-5.1-codex-max", "GPT-5.1 Codex Max"),
        codex_model("openai-gpt-5.1-codex-max", "OpenAI: GPT-5.1 Codex Max"),
        codex_model("gpt-5.1-codex", "GPT-5.1 Codex"),
        codex_model("codex-mini", "Codex Mini")
      ]

      normalized =
        ModelCatalog.available_models_from(models, current_model, configured_providers, true)

      assert Enum.map(normalized, & &1["id"]) == [
               "openai_codex:gpt-5.1-codex-max",
               "openai_codex:gpt-5.3-codex",
               "openai_codex:gpt-5.2-codex",
               "openai_codex:gpt-5.1-codex",
               "openai_codex:codex-mini"
             ]

      assert Enum.all?(normalized, &(&1["provider"] == "openai_codex"))
      refute Enum.any?(normalized, &String.contains?(&1["id"], "xhigh"))
      assert hd(normalized)["current"]
    end

    test "codex models stay hidden without oauth even when openai is configured" do
      models = [
        codex_model("gpt-5.3-codex", "GPT-5.3 Codex"),
        codex_model("gpt-5.1-codex-max", "GPT-5.1 Codex Max")
      ]

      normalized =
        ModelCatalog.available_models_from(models, "", MapSet.new([:openai]), false)

      assert normalized == []
    end

    test "current model sorts first when present" do
      models = ModelCatalog.available_models()

      if models != [] do
        current_id = List.last(models)["id"]
        [current | _rest] = ModelCatalog.available_models(current_id)

        assert current["id"] == current_id
        assert current["current"]
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

  defp codex_model(id, name) do
    %{
      id: id,
      name: name,
      provider: :openai,
      deprecated: false,
      retired: false,
      modalities: %{output: [:text]},
      limits: %{context: 400_000},
      cost: %{input: 1.75, output: 14}
    }
  end
end
