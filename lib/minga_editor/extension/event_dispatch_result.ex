defmodule MingaEditor.Extension.EventDispatchResult do
  @moduledoc """
  Normalized extension event dispatch result consumed by event effects.
  """

  alias Minga.Extension.CallbackInvoker
  alias MingaEditor.State, as: EditorState

  @type status :: :handled | :not_matched | :callback_failed

  @enforce_keys [:status, :state, :failures]
  defstruct [:status, :state, :failures]

  @type t :: %__MODULE__{
          status: status(),
          state: EditorState.t(),
          failures: [CallbackInvoker.failure()]
        }

  @spec handled(EditorState.t()) :: t()
  def handled(%EditorState{} = state),
    do: %__MODULE__{status: :handled, state: state, failures: []}

  @spec not_matched(EditorState.t()) :: t()
  def not_matched(%EditorState{} = state),
    do: %__MODULE__{status: :not_matched, state: state, failures: []}

  @spec callback_failed(EditorState.t(), nonempty_list(CallbackInvoker.failure())) :: t()
  def callback_failed(%EditorState{} = state, [_ | _] = failures) when is_list(failures),
    do: %__MODULE__{status: :callback_failed, state: state, failures: failures}
end
