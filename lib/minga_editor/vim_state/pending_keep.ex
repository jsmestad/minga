defmodule MingaEditor.VimState.PendingKeep do
  @moduledoc "An exact Keep request and the Vim input that depends on its result."

  alias MingaEditor.ChangeRecorder

  @type continuation ::
          :notice
          | :blocking
          | {:normal, pos_integer() | nil}
          | {:visual, Minga.Mode.VisualState.t(), Minga.Buffer.position()}
  @type input :: {:key, ChangeRecorder.key()} | {:command, pid(), Minga.Mode.command()}

  @enforce_keys [:id, :buffer, :count, :continuation, :repeat_revision, :input]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: reference(),
          buffer: pid(),
          count: pos_integer(),
          continuation: continuation(),
          repeat_revision: non_neg_integer(),
          input: :queue.queue(input())
        }

  @doc "Captures only the facts needed after Keep replies for this editing context."
  @spec new(reference(), pid(), pos_integer(), continuation(), ChangeRecorder.t()) :: t()
  def new(id, buffer, count, continuation, recorder) do
    %__MODULE__{
      id: id,
      buffer: buffer,
      count: count,
      continuation: continuation,
      repeat_revision: recorder.revision,
      input: :queue.new()
    }
  end

  @doc "Holds dependent keys in input order; ordinary motion can precede the first dependent key."
  @spec hold(t(), ChangeRecorder.key(), Minga.Mode.mode()) :: {:held, t()} | :independent
  def hold(%__MODULE__{} = keep, key, mode) do
    if not :queue.is_empty(keep.input) or visual_waiting?(keep.continuation, mode) or
         (mode == :normal and dependent?(key)),
       do: {:held, enqueue(keep, {:key, key})},
       else: :independent
  end

  @spec visual_waiting?(continuation(), Minga.Mode.mode()) :: boolean()
  defp visual_waiting?({:visual, _, _}, mode), do: mode in [:visual, :visual_line]
  defp visual_waiting?(_other, _mode), do: false

  @spec enqueue(t(), input()) :: t()
  def enqueue(%__MODULE__{} = keep, input),
    do: %{keep | input: :queue.in(input, keep.input)}

  @spec dependent?(ChangeRecorder.key()) :: boolean()
  defp dependent?({codepoint, 0}) when codepoint in [?., ?u, ?[, ?]], do: true
  defp dependent?({?r, mods}) when mods > 0, do: true
  defp dependent?(_key), do: false
end
