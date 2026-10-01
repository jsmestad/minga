defmodule MingaAgent.ModelSelection do
  @moduledoc """
  Immutable authority for one executable native model selection.

  Persisted values decode into `Stored`, which deliberately has no ReqLLM model.
  A selection becomes active only after its exact route has been validated and
  materialized into one inline `LLMDB.Model`.
  """

  @version 2

  alias __MODULE__.Credential.{ApiKey, None, OAuth}
  alias __MODULE__.{Evidence, Policy, Route, Stored}

  @enforce_keys [
    :backend_id,
    :backend_module,
    :route,
    :request_model,
    :credential,
    :policy,
    :evidence
  ]
  defstruct @enforce_keys

  @type capability :: Policy.capability()
  @type credential_ref :: ApiKey.t() | OAuth.t() | None.t()
  @type t :: %__MODULE__{
          backend_id: String.t(),
          backend_module: module(),
          route: Route.t(),
          request_model: LLMDB.Model.t(),
          credential: credential_ref(),
          policy: Policy.t(),
          evidence: Evidence.t()
        }

  @doc "Returns the persistence codec version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Constructs the only valid form of a newly active selection."
  @spec build(map(), Route.t(), credential_ref(), Policy.t(), Evidence.t()) ::
          {:ok, t()} | {:error, term()}
  def build(
        provider_spec,
        %Route{} = route,
        credential,
        %Policy{} = policy,
        %Evidence{} = evidence
      )
      when is_map(provider_spec) do
    with backend_id when is_binary(backend_id) and backend_id != "" <- Map.get(provider_spec, :id),
         backend_module when is_atom(backend_module) <- Map.get(provider_spec, :module),
         :ok <- validate_credential(credential, route),
         {:ok, request_model} <- Route.materialize(route) do
      {:ok,
       %__MODULE__{
         backend_id: backend_id,
         backend_module: backend_module,
         route: route,
         request_model: request_model,
         credential: credential,
         policy: policy,
         evidence: evidence
       }}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_model_selection}
    end
  end

  @doc "Decodes and validates persisted data without making it executable."
  @spec decode(map()) :: {:ok, Stored.t()} | {:error, term()}
  def decode(%{"version" => @version} = data) do
    with backend_id when is_binary(backend_id) and backend_id != "" <- Map.get(data, "backend_id"),
         {:ok, route} <- Route.decode(Map.get(data, "route", %{})),
         {:ok, credential} <- decode_credential(Map.get(data, "credential", %{})),
         {:ok, policy} <- decode_policy(Map.get(data, "policy", %{})),
         {:ok, evidence} <- decode_evidence(Map.get(data, "evidence", %{})),
         :ok <- validate_credential(credential, route) do
      {:ok, Stored.new(backend_id, route, credential, policy, evidence)}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_model_selection}
    end
  end

  def decode(%{"version" => version}), do: {:error, {:unknown_model_selection_version, version}}
  def decode(_data), do: {:error, :invalid_model_selection}

  @doc "Materializes a decoded stored selection against its declared Minga backend."
  @spec materialize(Stored.t(), map()) :: {:ok, t()} | {:error, term()}
  def materialize(%Stored{} = stored, provider_spec) when is_map(provider_spec) do
    if Map.get(provider_spec, :id) == stored.backend_id do
      build(provider_spec, stored.route, stored.credential, stored.policy, stored.evidence)
    else
      {:error, {:backend_mismatch, stored.backend_id}}
    end
  end

  @doc "Encodes an active selection without runtime modules, models, paths, or secrets."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = selection) do
    %{
      "version" => @version,
      "backend_id" => selection.backend_id,
      "route" => Route.encode(selection.route),
      "credential" => encode_credential(selection.credential),
      "policy" => encode_policy(selection.policy),
      "evidence" => %{
        "status" => "unverified",
        "catalog" => selection.evidence.catalog,
        "custom" => selection.evidence.custom
      }
    }
  end

  @doc "Returns an opaque stable hash of the exact route and credential identity."
  @spec id(t() | Stored.t()) :: String.t()
  def id(%{backend_id: backend_id, route: route, credential: credential}) do
    identity = %{
      version: @version,
      backend_id: backend_id,
      route:
        Map.take(
          Route.encode(route),
          ~w(origin request_provider model_provider model_id execution)
        ),
      credential: credential_identity(credential)
    }

    encoded = :erlang.term_to_binary(identity, [:deterministic])
    digest = :crypto.hash(:sha256, encoded)
    "ms2_" <> Base.url_encode64(digest, padding: false)
  end

  @doc "Returns a human-readable, secret-free credential identity."
  @spec credential_id(credential_ref()) :: String.t()
  def credential_id(%ApiKey{provider: provider, source: source}), do: "#{provider}:#{source}"

  def credential_id(%OAuth{provider_key: provider_key, account_id: account_id}),
    do: "#{provider_key}:#{account_id}"

  def credential_id(%None{provider: provider}), do: "#{provider}:none"

  @doc "Returns true for a credential-free local Ollama selection."
  @spec local?(t()) :: boolean()
  def local?(%__MODULE__{credential: %None{provider: "ollama"}}), do: true
  def local?(%__MODULE__{}), do: false

  @doc "Returns true only when tool use is explicitly supported."
  @spec tools?(t()) :: boolean()
  def tools?(%__MODULE__{policy: %Policy{capabilities: %{tools: true}}}), do: true
  def tools?(%__MODULE__{}), do: false

  @doc "Returns true only when image input is explicitly supported."
  @spec images?(t()) :: boolean()
  def images?(%__MODULE__{policy: %Policy{capabilities: %{images: true}}}), do: true
  def images?(%__MODULE__{}), do: false

  @doc "Changes reasoning effort while preserving the immutable executable route."
  @spec with_reasoning(t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def with_reasoning(%__MODULE__{} = selection, effort) when is_binary(effort) do
    case Policy.with_reasoning(selection.policy, effort) do
      {:ok, policy} ->
        {:ok, %{selection | policy: policy}}

      {:error, :unsupported_reasoning} ->
        options = selection.policy.reasoning.options

        {:error,
         "Thinking level #{inspect(effort)} is not supported by #{selection.route.display_name} on #{selection.route.execution.wire_protocol}. Available: #{Enum.join(options, ", ")}"}
    end
  end

  @spec validate_credential(credential_ref(), Route.t()) :: :ok | {:error, :invalid_credential}
  defp validate_credential(
         %ApiKey{provider: owner, source: source},
         %Route{origin: {_kind, owner, _model}, request_provider: request_provider}
       )
       when is_binary(owner) and owner != "" and source in [:env, :file] and
              request_provider != :openai_codex,
       do: :ok

  defp validate_credential(
         %OAuth{
           provider: :openai_codex,
           provider_key: "openai-codex",
           account_id: account_id,
           source_id: source_id
         },
         %Route{request_provider: :openai_codex, origin: {:catalog, "openai", _model}}
       )
       when is_binary(account_id) and account_id != "" and is_binary(source_id) and
              byte_size(source_id) == 64,
       do: :ok

  defp validate_credential(
         %None{provider: "ollama"},
         %Route{request_provider: :ollama, origin: {:catalog, "ollama", _model}}
       ),
       do: :ok

  defp validate_credential(
         %None{provider: owner},
         %Route{origin: {:custom, owner, _model}}
       ),
       do: :ok

  defp validate_credential(_credential, _route), do: {:error, :invalid_credential}

  @spec encode_credential(credential_ref()) :: map()
  defp encode_credential(%ApiKey{} = credential) do
    %{
      "kind" => "api_key",
      "provider" => credential.provider,
      "source" => Atom.to_string(credential.source)
    }
  end

  defp encode_credential(%OAuth{} = credential) do
    %{
      "kind" => "oauth",
      "provider" => "openai_codex",
      "provider_key" => credential.provider_key,
      "account_id" => credential.account_id,
      "source_id" => credential.source_id
    }
  end

  defp encode_credential(%None{} = credential) do
    %{"kind" => "none", "provider" => credential.provider}
  end

  @spec decode_credential(map()) :: {:ok, credential_ref()} | {:error, :invalid_credential}
  defp decode_credential(%{"kind" => "api_key", "provider" => provider, "source" => "env"})
       when is_binary(provider) and provider != "" do
    {:ok, ApiKey.new(provider, :env)}
  end

  defp decode_credential(%{"kind" => "api_key", "provider" => provider, "source" => "file"})
       when is_binary(provider) and provider != "" do
    {:ok, ApiKey.new(provider, :file)}
  end

  defp decode_credential(%{
         "kind" => "oauth",
         "provider" => "openai_codex",
         "provider_key" => "openai-codex",
         "account_id" => account_id,
         "source_id" => source_id
       })
       when is_binary(account_id) and account_id != "" and
              is_binary(source_id) and byte_size(source_id) == 64 do
    {:ok, OAuth.restore(account_id, source_id)}
  end

  defp decode_credential(%{"kind" => "none", "provider" => provider})
       when is_binary(provider) and provider != "" do
    {:ok, None.new(provider)}
  end

  defp decode_credential(_data), do: {:error, :invalid_credential}

  @spec encode_policy(Policy.t()) :: map()
  defp encode_policy(%Policy{} = policy) do
    %{
      "reasoning" => %{
        "effort" => policy.reasoning.effort,
        "options" => policy.reasoning.options
      },
      "limits" => MingaAgent.ModelSelection.Encoding.stringify(Map.from_struct(policy.limits)),
      "capabilities" => stringify_capabilities(Map.from_struct(policy.capabilities)),
      "cost" => MingaAgent.ModelSelection.Encoding.stringify(policy.cost)
    }
  end

  @spec decode_policy(map()) :: {:ok, Policy.t()} | {:error, :invalid_policy}
  defp decode_policy(data) when is_map(data) do
    reasoning = Map.get(data, "reasoning", %{})
    limits = Map.get(data, "limits", %{})
    capabilities = Map.get(data, "capabilities", %{})

    Policy.new(%{
      reasoning: %{
        effort: Map.get(reasoning, "effort"),
        options: Map.get(reasoning, "options")
      },
      limits: %{
        context: Map.get(limits, "context"),
        input: Map.get(limits, "input"),
        output: Map.get(limits, "output"),
        request_output: Map.get(limits, "request_output")
      },
      capabilities: %{
        tools: decode_capability(Map.get(capabilities, "tools")),
        images: decode_capability(Map.get(capabilities, "images")),
        streaming: decode_capability(Map.get(capabilities, "streaming"))
      },
      cost: Map.get(data, "cost", %{})
    })
  end

  defp decode_policy(_data), do: {:error, :invalid_policy}

  @spec decode_evidence(map()) :: {:ok, Evidence.t()} | {:error, :invalid_evidence}
  defp decode_evidence(%{
         "status" => "unverified",
         "catalog" => catalog,
         "custom" => custom
       })
       when is_boolean(catalog) and is_boolean(custom),
       do: {:ok, Evidence.new(catalog, custom)}

  defp decode_evidence(_data), do: {:error, :invalid_evidence}

  @spec decode_capability(term()) :: capability() | :invalid
  defp decode_capability(true), do: true
  defp decode_capability(false), do: false
  defp decode_capability("unknown"), do: :unknown
  defp decode_capability(_value), do: :invalid

  @spec stringify_capabilities(Policy.capabilities()) :: map()
  defp stringify_capabilities(capabilities) do
    Map.new(capabilities, fn
      {key, :unknown} -> {Atom.to_string(key), "unknown"}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  @spec credential_identity(credential_ref()) :: map()
  defp credential_identity(%ApiKey{} = credential) do
    %{kind: :api_key, provider: credential.provider, source: credential.source}
  end

  defp credential_identity(%OAuth{} = credential) do
    %{
      kind: :oauth,
      provider: credential.provider,
      provider_key: credential.provider_key,
      account_id: credential.account_id,
      source_id: credential.source_id
    }
  end

  defp credential_identity(%None{} = credential),
    do: %{kind: :none, provider: credential.provider}
end
