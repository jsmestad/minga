defmodule MingaAgent.Question.Pending do
  @moduledoc "One admitted clarification and the monitored tool worker waiting for its result."

  alias MingaAgent.Question
  alias MingaAgent.Question.Target

  @enforce_keys [:target, :question, :reply_to, :monitor]
  defstruct [:target, :question, :reply_to, :monitor]

  @type t :: %__MODULE__{
          target: Target.t(),
          question: Question.t(),
          reply_to: GenServer.from(),
          monitor: reference()
        }
end
