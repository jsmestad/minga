defmodule MingaEditor.Agent.StartRequest do
  @moduledoc """
  The options of one local Agent session start, kept so a failed start can run again unchanged.

  `hooks?` enables the SessionStart hooks, `recover?` recovers interrupted work, and `follow_up` is the work that runs once the started session is bound (see `MingaEditor.Agent.SessionStart`). A follow-up runs only when its session binds, so a failed start never ran it and a retry runs it once.
  """

  alias MingaEditor.Agent.SessionStart

  @enforce_keys [:hooks?, :recover?, :follow_up]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hooks?: boolean(),
          recover?: boolean(),
          follow_up: SessionStart.follow_up()
        }

  @doc "Names the options of one start."
  @spec new(boolean(), boolean(), SessionStart.follow_up()) :: t()
  def new(hooks?, recover?, follow_up) when is_boolean(hooks?) and is_boolean(recover?),
    do: %__MODULE__{hooks?: hooks?, recover?: recover?, follow_up: follow_up}

  @doc "The options of an ordinary start that runs hooks, recovers interrupted work and has no follow-up."
  @spec default() :: t()
  def default, do: new(true, true, nil)
end
