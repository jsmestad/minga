defmodule MingaEditor.Extension.EventEffect.Result do
  @moduledoc """
  Callback completion carried across the effect process boundary.

  An unchanged candidate refers to the request's existing snapshot instead of copying the same Editor state into every result message.
  """

  alias MingaEditor.Extension.EventDispatchResult
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:status, :state, :failures]
  defstruct [:status, :state, :failures]

  @type t :: %__MODULE__{
          status: EventDispatchResult.status(),
          state: :base | EditorState.t(),
          failures: [Minga.Extension.CallbackInvoker.failure()]
        }

  @type resolved :: %__MODULE__{
          status: EventDispatchResult.status(),
          state: EditorState.t(),
          failures: [Minga.Extension.CallbackInvoker.failure()]
        }

  @doc "Keeps a changed candidate, or refers to an exactly unchanged base snapshot."
  @spec from_dispatch(EventDispatchResult.t(), EditorState.t()) :: t()
  def from_dispatch(%EventDispatchResult{} = result, %EditorState{} = base) do
    candidate = if result.state === base, do: :base, else: result.state
    %__MODULE__{status: result.status, state: candidate, failures: result.failures}
  end

  @doc "Resolves the candidate against the request's snapshot before the normal stale check."
  @spec resolve(t(), EditorState.t()) :: resolved()
  def resolve(%__MODULE__{state: :base} = result, %EditorState{} = base),
    do: %{result | state: base}

  def resolve(%__MODULE__{state: %EditorState{}} = result, %EditorState{}), do: result
end
