defmodule MingaEditor.Agent.ConnectionPrompt do
  @moduledoc "The original workspace and exact setup operation waiting for local credential input."

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaAgent.Credentials.Secret
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaEditor.Agent.{ConnectionInput, ConnectionSetup}
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:workspace_id, :target, :operation_ref, :kind]
  defstruct [:workspace_id, :target, :operation_ref, :kind]

  @type t :: %__MODULE__{
          workspace_id: non_neg_integer(),
          target: ConnectionTarget.t(),
          operation_ref: reference(),
          kind: ConnectionInput.input_kind()
        }

  @doc "Checks whether the derived Session connection still owns this input request."
  @spec current?(t(), ConnectionSnapshot.t() | nil) :: boolean()
  def current?(%__MODULE__{target: target, operation_ref: ref}, %ConnectionSnapshot{
        target: target,
        operation: {:connecting, ref}
      }),
      do: true

  def current?(%__MODULE__{}, _connection), do: false

  @impl true
  @spec label() :: String.t()
  def label, do: "API key: "

  @impl true
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(_text, state),
    do: NoticeWorkflow.publish(state, "Open Models and connections to enter an API key.")

  @impl true
  @spec on_submit(String.t(), EditorState.t(), map() | nil) :: EditorState.t()
  def on_submit(text, state, %__MODULE__{} = prompt),
    do: ConnectionSetup.submit(state, prompt, Secret.new(text))

  def on_submit(text, state, _context), do: on_submit(text, state)

  @impl true
  @spec on_cancel(EditorState.t(), map() | nil) :: EditorState.t()
  def on_cancel(state, %__MODULE__{} = prompt), do: ConnectionSetup.cancel(state, prompt)
  def on_cancel(state, _context), do: state
end
