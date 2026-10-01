defmodule MingaAgent.ModelSelection.Credential.OAuth do
  @moduledoc "Pinned OpenAI Codex OAuth account identity."
  @enforce_keys [:provider, :provider_key, :account_id]
  defstruct [:provider, :provider_key, :account_id, :oauth_path]

  @type t :: %__MODULE__{
          provider: :openai_codex,
          provider_key: String.t(),
          account_id: String.t(),
          oauth_path: String.t() | nil
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
      oauth_path: oauth_path
    }
  end
end
