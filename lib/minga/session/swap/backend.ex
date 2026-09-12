defmodule Minga.Session.Swap.Backend do
  @moduledoc """
  Storage boundary for generation-aware swap publication.

  Implementations prepare complete swap data away from the Buffer process. The
  Buffer process remains the publication authority and calls `publish/1` only
  after it verifies that the prepared generation is still current.
  """

  @typedoc "Opaque prepared swap value owned by the backend."
  @type prepared :: term()

  @callback prepare(String.t(), binary(), keyword()) ::
              {:ok, prepared()} | {:error, term()}
  @callback publish(prepared()) :: :ok | {:error, term()}
  @callback discard(prepared()) :: :ok | {:error, term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
end
