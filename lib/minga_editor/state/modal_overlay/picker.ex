defmodule MingaEditor.State.ModalOverlay.Picker do
  @moduledoc """
  Modal-overlay payload for the picker variant.

  Wraps the existing `MingaEditor.State.Picker` struct with the metadata the
  ModalOverlay sum type carries for every variant: `opened_at` (monotonic
  millisecond timestamp) and `owner` (a tag identifying the lifecycle scope
  the modal belongs to).

  The picker is global UX, so `owner` defaults to `:global`. It is included
  here for API uniformity with the per-tab variants (`Completion`,
  `Conflict`).
  """

  alias MingaEditor.State.Picker, as: PickerState

  @type owner :: term()

  @type t :: %__MODULE__{
          picker_ui: PickerState.t(),
          owner: owner(),
          opened_at: integer()
        }

  @enforce_keys [:picker_ui]
  defstruct picker_ui: %PickerState{}, owner: :global, opened_at: 0

  @doc """
  Builds a picker payload wrapping the given `picker_ui` state.

  The optional `:owner` keyword defaults to `:global`. The optional
  `:opened_at` keyword defaults to `System.monotonic_time(:millisecond)`.
  """
  @spec new(PickerState.t(), keyword()) :: t()
  def new(%PickerState{} = picker_ui, opts \\ []) do
    %__MODULE__{
      picker_ui: picker_ui,
      owner: Keyword.get(opts, :owner, :global),
      opened_at: Keyword.get(opts, :opened_at, System.monotonic_time(:millisecond))
    }
  end
end
