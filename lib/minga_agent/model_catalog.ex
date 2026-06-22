defmodule MingaAgent.ModelCatalog do
  @moduledoc """
  Curated model catalog for the native agent provider.

  Wraps LLMDB to return models filtered to providers the user has
  credentials for, excluding non-chat models (embeddings, image gen,
  TTS, etc.) and deprecated/retired entries.

  When an OAuth token is present, codex models from LLMDB's `:openai`
  provider are included and re-tagged as `openai_codex` so ReqLLM
  routes them through the Codex Responses API with OAuth auth.

  The output format matches what `MingaEditor.UI.Picker.AgentModelSource`
  expects: a list of maps with string keys for `"id"`, `"name"`,
  `"provider"`, `"context_window"`, and `"cost"`.
  """

  alias MingaAgent.Credentials

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
    oauth = Credentials.oauth_configured?()

    LLMDB.models()
    |> Enum.filter(&include_model?(&1, configured_providers, oauth))
    |> Enum.map(&format_model(&1, current_model, oauth))
    |> dedupe_models()
    |> Enum.sort_by(&model_sort_key/1)
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

  @excluded_patterns ~w(embedding tts whisper moderation realtime dall-e sora imagen veo aqa gemma duo-chat)

  @spec include_model?(map(), MapSet.t(atom()), boolean()) :: boolean()
  defp include_model?(model, configured_providers, oauth) do
    provider_available?(model, configured_providers, oauth) and
      not model.deprecated and
      not model.retired and
      has_text_output?(model) and
      has_reasonable_context?(model) and
      not excluded_by_name?(model.id)
  end

  defp provider_available?(model, configured_providers, oauth) do
    if codex_model?(model) do
      oauth and model.provider == :openai
    else
      model.provider in configured_providers
    end
  end

  defp codex_model?(%{id: id}), do: String.contains?(String.downcase(id), "codex")

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

  @spec format_model(map(), String.t(), boolean()) :: model_entry()
  defp format_model(model, current_model, oauth) do
    canonical_id = canonical_model_id(model)

    {provider_str, full_id} =
      if codex_model?(model) and oauth do
        {"openai_codex", "openai_codex:#{canonical_id}"}
      else
        provider = Atom.to_string(model.provider)
        {provider, "#{provider}:#{canonical_id}"}
      end

    %{
      "id" => full_id,
      "name" => display_name(model, canonical_id),
      "provider" => provider_str,
      "context_window" => model.limits[:context],
      "cost" => format_cost(model.cost),
      "current" => full_id == current_model
    }
  end

  @spec canonical_model_id(map()) :: String.t()
  defp canonical_model_id(%{id: id, provider: provider} = model) do
    provider_prefix = provider |> Atom.to_string() |> Kernel.<>("/")

    id
    |> String.trim()
    |> String.replace_prefix(provider_prefix, "")
    |> canonicalize_codex_id(model)
  end

  @spec canonicalize_codex_id(String.t(), map()) :: String.t()
  defp canonicalize_codex_id(id, model) do
    if codex_model?(model) do
      id
      |> String.replace_prefix("openai/", "")
      |> String.replace_prefix("openai-", "")
      |> normalize_codex_version_alias()
    else
      id
    end
  end

  @spec normalize_codex_version_alias(String.t()) :: String.t()
  defp normalize_codex_version_alias(id) do
    id = Regex.replace(~r/^gpt-(\d)-(\d)(-.+)$/, id, "gpt-\\1.\\2\\3")
    Regex.replace(~r/^gpt-(\d)(\d)(-.+)$/, id, "gpt-\\1.\\2\\3")
  end

  @spec display_name(map(), String.t()) :: String.t()
  defp display_name(model, canonical_id) do
    if codex_model?(model) do
      codex_display_name(canonical_id)
    else
      model.name || canonical_id
    end
  end

  @spec codex_display_name(String.t()) :: String.t()
  defp codex_display_name("codex-mini"), do: "Codex Mini"

  defp codex_display_name("gpt-" <> rest) do
    case String.split(rest, "-", trim: true) do
      [version, "codex" | variants] -> gpt_codex_display_name(version, variants)
      _other -> titleize_model_id("gpt-" <> rest)
    end
  end

  defp codex_display_name(id), do: titleize_model_id(id)

  @spec gpt_codex_display_name(String.t(), [String.t()]) :: String.t()
  defp gpt_codex_display_name(version, variants) do
    suffix = variants |> Enum.map_join(" ", &String.capitalize/1)
    String.trim("GPT-#{version} Codex #{suffix}")
  end

  @spec titleize_model_id(String.t()) :: String.t()
  defp titleize_model_id(id) do
    id
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &titleize_model_part/1)
  end

  @spec titleize_model_part(String.t()) :: String.t()
  defp titleize_model_part("gpt"), do: "GPT"
  defp titleize_model_part(part), do: String.capitalize(part)

  @spec dedupe_models([model_entry()]) :: [model_entry()]
  defp dedupe_models(models) do
    models
    |> Enum.group_by(& &1["id"])
    |> Enum.map(fn {_id, entries} -> best_model_entry(entries) end)
  end

  @spec best_model_entry([model_entry()]) :: model_entry()
  defp best_model_entry([entry | rest]) do
    Enum.reduce(rest, entry, &prefer_model_entry/2)
  end

  @spec prefer_model_entry(model_entry(), model_entry()) :: model_entry()
  defp prefer_model_entry(candidate, incumbent) do
    if model_quality_key(candidate) < model_quality_key(incumbent), do: candidate, else: incumbent
  end

  @spec model_quality_key(model_entry()) :: {integer(), integer(), integer()}
  defp model_quality_key(model) do
    name = model["name"] || ""

    {
      prefixed_name_rank(name),
      lowercase_name_rank(name),
      String.length(name)
    }
  end

  @spec prefixed_name_rank(String.t()) :: integer()
  defp prefixed_name_rank("OpenAI: " <> _rest), do: 1
  defp prefixed_name_rank(_name), do: 0

  @spec lowercase_name_rank(String.t()) :: integer()
  defp lowercase_name_rank(name), do: if(name == String.downcase(name), do: 1, else: 0)

  @provider_sort_order %{
    "openai_codex" => 0,
    "anthropic" => 1,
    "openai" => 2,
    "google" => 3
  }

  @spec model_sort_key(model_entry()) :: tuple()
  defp model_sort_key(model) do
    id = model["id"] || ""
    provider = model["provider"] || ""

    {
      current_rank(model),
      Map.get(@provider_sort_order, provider, 99),
      model_family_rank(id),
      model_version_key(id),
      model_variant_rank(id),
      String.downcase(model["name"] || id)
    }
  end

  @spec current_rank(model_entry()) :: integer()
  defp current_rank(%{"current" => true}), do: 0
  defp current_rank(_model), do: 1

  @spec model_family_rank(String.t()) :: integer()
  defp model_family_rank(id) do
    if String.contains?(id, "gpt-"), do: 0, else: 1
  end

  @spec model_version_key(String.t()) :: [integer()]
  defp model_version_key(id) do
    case Regex.run(~r/gpt-(\d+(?:\.\d+)?)/, id) do
      [_match, version] ->
        version |> String.split(".") |> padded_version_parts() |> Enum.map(&negative_integer/1)

      nil ->
        []
    end
  end

  @spec padded_version_parts([String.t()]) :: [String.t()]
  defp padded_version_parts([major]), do: [major, "0"]
  defp padded_version_parts(parts), do: parts

  @spec negative_integer(String.t()) :: integer()
  defp negative_integer(value), do: value |> String.to_integer() |> Kernel.*(-1)

  @spec model_variant_rank(String.t()) :: integer()
  defp model_variant_rank(id) do
    id
    |> String.downcase()
    |> do_model_variant_rank()
  end

  @spec do_model_variant_rank(String.t()) :: integer()
  defp do_model_variant_rank(id) do
    model_variant_rank(
      String.contains?(id, "max"),
      String.contains?(id, "mini"),
      String.contains?(id, "spark")
    )
  end

  @spec model_variant_rank(boolean(), boolean(), boolean()) :: integer()
  defp model_variant_rank(true, _mini?, _spark?), do: 0
  defp model_variant_rank(false, false, false), do: 1
  defp model_variant_rank(false, true, _spark?), do: 2
  defp model_variant_rank(false, false, true), do: 3

  @spec format_cost(map()) :: map()
  defp format_cost(%{input: input, output: output}) do
    %{"input" => input, "output" => output}
  end

  defp format_cost(_), do: %{}
end
