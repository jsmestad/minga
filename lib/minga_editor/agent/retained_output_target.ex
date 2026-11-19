defmodule MingaEditor.Agent.RetainedOutputTarget do
  @moduledoc "Identifies one tool card in a committed resident transcript presentation."

  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.ToolCall
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.AgentRetainedOutputSource

  @type scope :: {non_neg_integer(), reference()}
  @type offer :: <<_::128>>

  @enforce_keys [:offer, :message_id]
  defstruct [:offer, :message_id]
  @type t :: %__MODULE__{offer: offer(), message_id: pos_integer()}

  @doc "Builds the target of the frontend action from its decoded wire fields."
  @spec new(offer(), pos_integer()) :: t()
  def new(offer, message_id), do: %__MODULE__{offer: offer, message_id: message_id}

  @doc "Projects a stable action offer only for a completed tool occurrence with retained bytes."
  @spec offer(scope() | nil, pos_integer(), ToolCall.t()) :: offer() | nil
  def offer({workspace, generation}, id, %ToolCall{
        status: status,
        output: %Output{reference: %Reference{token: token, sha256: digest}}
      })
      when status != :running do
    scope = :erlang.term_to_binary({workspace, generation, id})
    :sha256 |> :crypto.hash([scope, token, digest]) |> binary_part(0, 16)
  end

  def offer(_scope, _id, _tool), do: nil

  @doc "Opens only an unchanged, explicitly offered result in the originating conversation."
  @spec open(State.t(), t()) :: State.t()
  def open(state, %__MODULE__{offer: offer, message_id: id}) do
    with {:ok, workspace_id, %{target: %ConnectionTarget{} = target}} <-
           ConnectionAction.origin(state),
         {^id,
          {:tool_call, %ToolCall{output: %Output{reference: %Reference{} = reference}} = tool}} <-
           List.keyfind(state.workspace.agent_ui.panel.transcript.message_pairs, id, 0),
         ^offer <- offer({workspace_id, target.epoch}, id, tool) do
      AgentRetainedOutputSource.open(state, workspace_id, target, id, reference)
    else
      _stale ->
        NoticeWorkflow.publish(
          state,
          "The displayed tool result changed or is no longer retained."
        )
    end
  end
end
