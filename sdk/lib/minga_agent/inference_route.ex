defmodule MingaAgent.InferenceRoute do
  @moduledoc """
  Contract for a contributed model route that supplies model streams to Minga's native agent loop.

  A route produces model output only. Minga runs every tool, approval, retry, compaction, and history step. A route never executes a tool. The contract uses only Minga-owned values, so it stays stable when Minga changes its internal model library.

  This is a compile-time stub. At runtime, the real behaviour in Minga's BEAM VM is used.
  """

  alias MingaAgent.InferenceRoute.{Credential, Model, Request, Response}

  @type route_credential :: Credential.t() | nil

  @type availability ::
          {:ready, account_label :: String.t()}
          | {:unavailable, reason :: atom(), remedy :: String.t()}

  @type error_kind ::
          :auth_failed
          | :rate_limited
          | :usage_limit_reached
          | :unreachable
          | :invalid_model
          | :context_transition_required
          | :request_admission_refused
          | :provider_error
          | :tool_error
          | :internal_error
          | :unknown

  @callback models(config :: keyword()) :: [Model.t()]

  @callback availability(route_id :: String.t(), credential :: route_credential()) ::
              availability()

  @callback stream(Request.t()) :: {:ok, Response.t()} | {:error, term()}

  @callback classify_error(term()) :: {error_kind(), message :: String.t()}
end
