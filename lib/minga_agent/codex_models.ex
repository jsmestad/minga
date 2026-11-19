defmodule MingaAgent.CodexModels do
  @moduledoc "Account-scoped model eligibility from the authenticated Codex catalog."

  alias MingaAgent.Credentials
  alias MingaAgent.ModelSelection.Credential.OAuth

  @enforce_keys [:account_id, :source_id, :model_ids]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          account_id: String.t(),
          source_id: String.t(),
          model_ids: MapSet.t(String.t())
        }
  @type error ::
          :credentials_unavailable
          | :invalid_inventory
          | :request_failed
          | {:http_status, pos_integer()}
  @type result :: {:ok, t()} | {:error, error() | :not_loaded}

  @doc "Fetches one inventory using the exact account and source pinned by the caller."
  @spec fetch(OAuth.t(), keyword()) :: result()
  def fetch(%OAuth{} = credential, opts \\ []) do
    case Credentials.request_options(credential, opts) do
      {:ok, material} -> fetch_inventory(credential, material, opts)
      {:error, _reason} -> {:error, :credentials_unavailable}
    end
  end

  @spec fetch_inventory(OAuth.t(), keyword(), keyword()) :: result()
  defp fetch_inventory(credential, material, opts) do
    request_opts = [
      url: "https://chatgpt.com/backend-api/codex/models",
      params: [client_version: "0.154.0"],
      auth: {:bearer, Keyword.fetch!(material, :access_token)},
      headers: [{"chatgpt-account-id", credential.account_id}, {"originator", "minga"}],
      retry: false,
      redirect: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000]
    ]

    case Req.get(request_opts ++ Keyword.take(opts, [:plug])) do
      {:ok, %{status: 200, body: body}} -> from_response(credential, body)
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, _reason} -> {:error, :request_failed}
    end
  end

  @doc "Validates picker-visible wire model IDs without retaining provider response data."
  @spec from_response(OAuth.t(), term()) :: result()
  def from_response(%OAuth{} = credential, %{"models" => models}) when is_list(models) do
    case Enum.reduce_while(models, {:ok, MapSet.new(), MapSet.new()}, &collect_model/2) do
      {:ok, visible, _seen} ->
        {:ok,
         %__MODULE__{
           account_id: credential.account_id,
           source_id: credential.source_id,
           model_ids: visible
         }}

      {:error, _reason} = error ->
        error
    end
  end

  def from_response(%OAuth{}, _body), do: {:error, :invalid_inventory}

  @doc "Checks an exact dispatched model ID against the same account and credential source."
  @spec permits?(t(), OAuth.t(), String.t()) :: boolean()
  def permits?(
        %__MODULE__{account_id: account, source_id: source, model_ids: ids},
        %OAuth{account_id: account, source_id: source},
        model_id
      ),
      do: MapSet.member?(ids, model_id)

  def permits?(%__MODULE__{}, %OAuth{}, _model_id), do: false

  @doc "Explains discovery failure without exposing credentials or response bodies."
  @spec message(term()) :: String.t()
  def message({:http_status, 401}),
    do: "Codex model discovery requires a new login. Run /login, then reopen /model."

  def message(:not_loaded),
    do: "Codex model availability is still being checked. Reopen /model when the check finishes."

  def message(_reason),
    do:
      "Could not verify the models available to this Codex account. Retry /model or choose a configured API-key route."

  @spec collect_model(term(), {:ok, MapSet.t(String.t()), MapSet.t(String.t())}) ::
          {:cont, {:ok, MapSet.t(String.t()), MapSet.t(String.t())}}
          | {:halt, {:error, :invalid_inventory}}
  defp collect_model(%{"slug" => slug, "visibility" => visibility}, {:ok, visible, seen})
       when is_binary(slug) and slug != "" and visibility in ["list", "hide", "none"] do
    if MapSet.member?(seen, slug) do
      {:halt, {:error, :invalid_inventory}}
    else
      visible = if visibility == "list", do: MapSet.put(visible, slug), else: visible
      {:cont, {:ok, visible, MapSet.put(seen, slug)}}
    end
  end

  defp collect_model(_model, _acc), do: {:halt, {:error, :invalid_inventory}}
end
