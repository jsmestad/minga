defmodule MingaAgent.ModelSelection.Credential.OAuth do
  @moduledoc "Pinned OpenAI Codex OAuth account identity."
  @enforce_keys [:provider, :provider_key, :account_id]
  defstruct [:provider, :provider_key, :account_id, :oauth_path, :source_id]

  @type t :: %__MODULE__{
          provider: :openai_codex,
          provider_key: String.t(),
          account_id: String.t(),
          oauth_path: String.t() | nil,
          source_id: String.t() | nil
        }

  @doc "Pins a Codex account, with an optional request-local credential path."
  @spec new(String.t(), String.t() | nil) :: t()
  def new(account_id, oauth_path \\ nil)
      when is_binary(account_id) and account_id != "" and
             (is_nil(oauth_path) or (is_binary(oauth_path) and oauth_path != "")) do
    %__MODULE__{
      provider: :openai_codex,
      provider_key: "openai-codex",
      account_id: account_id,
      oauth_path: oauth_path,
      source_id: source_id(oauth_path)
    }
  end

  @doc "Restores a secret-free source binding without reconstructing its local path."
  @spec restore(String.t(), String.t()) :: t()
  def restore(account_id, source_id) when is_binary(account_id) and is_binary(source_id) do
    %__MODULE__{
      provider: :openai_codex,
      provider_key: "openai-codex",
      account_id: account_id,
      source_id: source_id
    }
  end

  @spec source_id(String.t() | nil) :: String.t() | nil
  defp source_id(nil), do: nil

  defp source_id(path) do
    :crypto.hash(:sha256, Path.expand(path)) |> Base.encode16(case: :lower)
  end
end
