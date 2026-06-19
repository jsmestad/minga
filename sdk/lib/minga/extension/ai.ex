defmodule Minga.Extension.AI do
  @moduledoc """
  Sanctioned text-generation helper for extensions.

  `stream/2` streams chunks to `reply_to` asynchronously; `complete/2`
  blocks until the full text is ready. The user's configured model is used
  by default.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type opts :: keyword()
  @type error :: :empty_response | {:provider_error, term()}
  @type event :: {:chunk, String.t()} | {:done, String.t()} | {:error, error()}

  @spec stream([message()], opts()) :: {:ok, reference()}
  def stream(_messages, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec complete([message()], opts()) :: {:ok, String.t()} | {:error, error()}
  def complete(_messages, _opts \\ []), do: raise("minga_sdk is compile-time only")
end
