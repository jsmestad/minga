defmodule MingaEditor.Agent.PendingQuestion do
  @moduledoc "The displayed clarification and the exact Session attachment it came from."

  alias MingaAgent.Question
  alias MingaAgent.Question.Target

  @enforce_keys [:session, :target, :question, :offer]
  defstruct [:session, :target, :question, :offer]

  @type t :: %__MODULE__{
          session: pid(),
          target: Target.t(),
          question: Question.t(),
          offer: pos_integer()
        }

  @doc "Binds a frontend offer to the displayed request without exposing runtime identity on the wire."
  @spec new(pid(), Target.t(), Question.t()) :: t()
  def new(session, %Target{} = target, %Question{} = question) when is_pid(session) do
    %__MODULE__{
      session: session,
      target: target,
      question: question,
      offer: System.unique_integer([:positive, :monotonic])
    }
  end
end
