defmodule MingaAgent.ModelSelection.Credential.RouteOwned do
  @moduledoc """
  Credential owned by a contributed model route.

  `account_ref` is the opaque, secret-free account label the route reports when it is ready, or nil before the route has reported one. It is part of the selection identity, so switching the route's account changes the selection. Core never sees a token.
  """

  @enforce_keys [:route_id, :account_ref]
  defstruct @enforce_keys

  @type t :: %__MODULE__{route_id: String.t(), account_ref: String.t() | nil}

  @doc "Pins a route and the account it reported."
  @spec new(String.t(), String.t() | nil) :: t()
  def new(route_id, account_ref)
      when is_binary(route_id) and route_id != "" and
             (is_nil(account_ref) or (is_binary(account_ref) and account_ref != "")) do
    %__MODULE__{route_id: route_id, account_ref: account_ref}
  end
end
