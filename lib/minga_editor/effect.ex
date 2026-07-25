defmodule MingaEditor.Effect do
  @moduledoc """
  Contract for typed slow effects owned by an Editor generation.

  Implementations own execution, coalescing, and result application. The
  scheduler only enforces resource policy and worker lifecycle; it never
  switches on a domain lane or result shape.
  """

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.State, as: EditorState

  @typedoc "A domain request struct implementing this behaviour."
  @type request :: struct()

  @callback run(request()) :: {:ok, term()} | {:error, term()}
  @callback coalesce(request(), request()) :: request()
  @callback apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  @callback render?(Outcome.t()) :: boolean()

  @optional_callbacks [coalesce: 2]
end
