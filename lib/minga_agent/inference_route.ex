defmodule MingaAgent.InferenceRoute do
  @moduledoc """
  Contract for a contributed model route that supplies model streams to Minga's native agent loop.

  A route produces model output only. Minga's native loop keeps ownership of turns, tool execution, approvals, retries, cost, compaction, and history. A route owns no sessions, credential files, retries, or tools, and it can never run a tool or skip an approval.

  The contract uses only Minga-owned values (`Request`, `Response`, `Event`, and friends), so it stays stable when Minga changes its internal model library. Per-route behavior is declared as data in `MingaAgent.InferenceRoute.Model` and fixed into `MingaAgent.ModelSelection.Policy` when a selection is built. Core modules never pattern-match on a specific route's id or module.
  """

  alias MingaAgent.Event
  alias MingaAgent.InferenceRoute.{Credential, Model, Request, Response}

  @typedoc "Opaque request credential that `MingaAgent.Credentials` resolves for one route."
  @type route_credential :: Credential.t() | nil

  @typedoc "Route-reported readiness. The account label is an opaque, secret-free identity."
  @type availability ::
          {:ready, account_label :: String.t()}
          | {:unavailable, reason :: atom(), remedy :: String.t()}

  @doc "Lists the models this route offers."
  @callback models(config :: keyword()) :: [Model.t()]

  @doc "Checks whether the route can serve requests without generating text."
  @callback availability(route_id :: String.t(), credential :: route_credential()) ::
              availability()

  @doc "Starts one streaming model request."
  @callback stream(Request.t()) :: {:ok, Response.t()} | {:error, term()}

  @doc "Maps a route failure onto a Minga error kind and one actionable sentence."
  @callback classify_error(term()) :: {Event.Error.kind(), message :: String.t()}

  @doc "Returns the callbacks every route module must export."
  @spec callbacks() :: [{atom(), arity()}]
  def callbacks, do: [models: 1, availability: 2, stream: 1, classify_error: 1]
end
