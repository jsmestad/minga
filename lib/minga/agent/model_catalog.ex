defmodule Minga.Agent.ModelCatalog do
  @moduledoc """
  Curated model catalog for the native agent provider.

  Wraps LLMDB to return models filtered to providers the user has
  credentials for, excluding non-chat models (embeddings, image gen,
  TTS, etc.) and deprecated/retired entries.

  The output format matches what `Minga.Picker.AgentModelSource`
  expects: a list of maps with string keys for `"id"`, `"name"`,
  `"provider"`, `"context_window"`, and `"cost"`.
  """

  alias Minga.Agent.Credentials

  @typedoc "A model entry suitable for the picker."
  @type model_entry :: %{
          String.t() => String.t() | integer() | map() | boolean()
        }

  @doc """
  Returns available chat models for providers the user has API keys for.

  `current_model` is the full `"provider:model_id"` string of the
  currently active model, used to mark it in the list.
  """
  @spec available_models(String.t()) :: [model_entry()]
  def available_models(current_model \\ "") do
    configured_providers = configured_provider_atoms()

    LLMDB.models()
    |> Enum.filter(&include_model?(&1, configured_providers))
    |> Enum.sort_by(&{&1.provider, &1.name})
    |> Enum.map(&format_model(&1, current_model))
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  # Maps our credential provider strings to LLMDB provider atoms.
  @provider_mapping %{
    "anthropic" => :anthropic,
    "openai" => :openai,
    "google" => :google
  }

  @spec configured_provider_atoms() :: MapSet.t(atom())
  defp configured_provider_atoms do
    Credentials.known_providers()
    |> Enum.filter(&has_credentials?/1)
    |> Enum.map(&Map.get(@provider_mapping, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @spec has_credentials?(String.t()) :: boolean()
  defp has_credentials?(provider) do
    case Credentials.resolve(provider) do
      {:ok, _key, _source} -> true
      _ -> false
    end
  end

  # Non-chat model ID substrings to exclude.
  @excluded_patterns ~w(embedding tts whisper moderation realtime dall-e sora codex imagen veo aqa gemma)

  @spec include_model?(map(), MapSet.t(atom())) :: boolean()
  defp include_model?(model, configured_providers) do
    model.provider in configured_providers and
      not model.deprecated and
      not model.retired and
      has_text_output?(model) and
      has_reasonable_context?(model) and
      not excluded_by_name?(model.id)
  end

  @spec has_text_output?(map()) :: boolean()
  defp has_text_output?(%{modalities: %{output: outputs}}) when is_list(outputs) do
    :text in outputs
  end

  defp has_text_output?(_), do: false

  @spec has_reasonable_context?(map()) :: boolean()
  defp has_reasonable_context?(%{limits: %{context: ctx}}) when is_integer(ctx) and ctx > 1000 do
    true
  end

  defp has_reasonable_context?(_), do: false

  @spec excluded_by_name?(String.t()) :: boolean()
  defp excluded_by_name?(id) do
    id_lower = String.downcase(id)
    Enum.any?(@excluded_patterns, &String.contains?(id_lower, &1))
  end

  @spec format_model(map(), String.t()) :: model_entry()
  defp format_model(model, current_model) do
    provider_str = Atom.to_string(model.provider)
    full_id = "#{provider_str}:#{model.id}"

    %{
      "id" => full_id,
      "name" => model.name || model.id,
      "provider" => provider_str,
      "context_window" => model.limits[:context],
      "cost" => format_cost(model.cost),
      "current" => full_id == current_model
    }
  end

  @spec format_cost(map()) :: map()
  defp format_cost(%{input: input, output: output}) do
    %{"input" => input, "output" => output}
  end

  defp format_cost(_), do: %{}
end
