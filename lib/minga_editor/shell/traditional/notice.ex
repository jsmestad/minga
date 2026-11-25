defmodule MingaEditor.Shell.Traditional.Notice do
  @moduledoc """
  Pure lifecycle owner for the traditional shell's ordinary status notice.

  The monotonic identity survives dismissal so a stale timeout can never
  dismiss a later notice. The timer handle is bookkeeping only and is not the
  notice identity.
  """

  alias Minga.RenderModel.UI.EmptyList.Action

  @type id :: non_neg_integer()
  @typedoc "A notice's message, and the next steps it names (`docs/design/anatomy.md`, \"Notice\")."
  @type t :: %__MODULE__{
          id: id(),
          message: String.t() | nil,
          actions: [Action.t()],
          timer: reference() | nil
        }

  defstruct id: 0, message: nil, actions: [], timer: nil

  @doc "Publishes a latest-wins notice, with the next steps it names, and advances its semantic identity."
  @spec publish(t(), String.t(), [Action.t()]) :: t()
  def publish(%__MODULE__{} = notice, message, actions \\ [])
      when is_binary(message) and is_list(actions) do
    %__MODULE__{id: notice.id + 1, message: message, actions: actions}
  end

  @doc "Records the timer handle only when it belongs to the current identity."
  @spec record_timer(t(), id(), reference()) :: t()
  def record_timer(%__MODULE__{id: id, message: message} = notice, id, timer)
      when is_binary(message) and is_reference(timer) do
    %{notice | timer: timer}
  end

  def record_timer(%__MODULE__{} = notice, _id, _timer), do: notice

  @doc "Acknowledges the current notice before keyboard command dispatch."
  @spec acknowledge(t()) :: t()
  def acknowledge(%__MODULE__{} = notice), do: clear(notice)

  @doc "Dismisses the current notice explicitly."
  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = notice), do: clear(notice)

  @doc "Expires the notice only when the delivered semantic identity matches."
  @spec timeout(t(), id()) :: t()
  def timeout(%__MODULE__{id: id} = notice, id), do: clear(notice)
  def timeout(%__MODULE__{} = notice, _stale_id), do: notice

  @doc "Returns whether an ordinary notice is currently present."
  @spec present?(t()) :: boolean()
  def present?(%__MODULE__{message: message}), do: is_binary(message)

  @spec clear(t()) :: t()
  defp clear(%__MODULE__{message: nil, timer: nil, actions: []} = notice), do: notice
  defp clear(%__MODULE__{} = notice), do: %{notice | message: nil, actions: [], timer: nil}
end
