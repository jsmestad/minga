defmodule MingaEditor.Agent.Tasks.Starting do
  @moduledoc """
  A task you started from the tasks drawer whose session has not bound yet.

  It shows at once, working and selected, so starting a task answers in the frame you pressed `↩`. When its session binds it becomes that session's task; when the start fails it shows as failed with the reason, until you start another task or close it with a new start.
  """

  @type t :: %__MODULE__{
          id: reference(),
          seq: non_neg_integer(),
          title: String.t(),
          started_at: integer(),
          failure: String.t() | nil
        }

  @enforce_keys [:id, :seq, :title, :started_at]
  defstruct [:id, :seq, :title, :started_at, failure: nil]

  @doc "The state a starting task shows."
  @spec state(t()) :: :working | :failed
  def state(%__MODULE__{failure: nil}), do: :working
  def state(%__MODULE__{}), do: :failed

  @doc "What a starting task says after its state word."
  @spec words(t()) :: String.t()
  def words(%__MODULE__{failure: nil}), do: "Starting"

  def words(%__MODULE__{failure: failure}),
    do: "#{Minga.Design.Tokens.state_word(:failed)} · #{failure}"

  @doc "Marks the start failed with the words the user reads."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = starting, message) when is_binary(message),
    do: %{starting | failure: message}
end
