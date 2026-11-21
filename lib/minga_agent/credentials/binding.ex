defmodule MingaAgent.Credentials.Binding do
  @moduledoc "Private runtime binding to resolved authentication material; never persisted."

  @derive {Inspect, only: [:identity]}
  @enforce_keys [:identity, :material]
  defstruct @enforce_keys

  @type t :: %__MODULE__{identity: map(), material: keyword()}

  @doc "Represents the absence of authentication material on the local route."
  @spec none() :: t()
  def none, do: %__MODULE__{identity: %{kind: :none}, material: []}

  @doc "Binds API-key continuity to the actual material in this runtime only."
  @spec api_key(keyword(), t() | nil) :: t()
  def api_key(material, %__MODULE__{material: material} = binding), do: binding

  def api_key(material, _previous) do
    identity = %{
      kind: :api_key,
      runtime_binding: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    }

    %__MODULE__{identity: identity, material: material}
  end

  @doc "Binds validated OAuth material to its authoritative account and source."
  @spec oauth(keyword(), String.t(), String.t()) :: t()
  def oauth(material, account_id, source_id) do
    %__MODULE__{
      identity: %{kind: :oauth, account_id: account_id, source_id: source_id},
      material: material
    }
  end

  @doc "Binds a contributed route's request material to its route and reported account."
  @spec route(keyword(), String.t(), String.t() | nil) :: t()
  def route(material, route_id, account_ref) do
    %__MODULE__{
      identity: %{kind: :route_owned, route_id: route_id, account_ref: account_ref},
      material: material
    }
  end
end
