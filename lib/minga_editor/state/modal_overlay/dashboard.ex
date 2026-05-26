defmodule MingaEditor.State.ModalOverlay.Dashboard do
  @moduledoc """
  Modal-overlay payload for the dashboard home screen.

  Wraps the existing `MingaEditor.Dashboard.state()` map (cursor + items)
  with the metadata every ModalOverlay variant carries. The dashboard is
  global UX, so `owner` defaults to `:global`.

  Scoped to the Traditional shell. Non-Traditional shell states may declare
  `dashboard: nil` in its typespec because Board does not surface the
  dashboard; opening this variant while the active shell is Board would
  violate that type. Callers that want a dashboard-style affordance on
  Board should add a Board-specific variant rather than reusing this one.
  """

  alias MingaEditor.Dashboard

  @type owner :: term()

  @type t :: %__MODULE__{
          state: Dashboard.state(),
          owner: owner(),
          opened_at: integer()
        }

  @enforce_keys [:state]
  defstruct [:state, owner: :global, opened_at: 0]

  @doc "Builds a dashboard payload wrapping the given dashboard state map."
  @spec new(Dashboard.state(), keyword()) :: t()
  def new(state, opts \\ []) when is_map(state) do
    %__MODULE__{
      state: state,
      owner: Keyword.get(opts, :owner, :global),
      opened_at: Keyword.get(opts, :opened_at, System.monotonic_time(:millisecond))
    }
  end

  @doc """
  Replaces the inner dashboard state on the payload, preserving `owner` and
  `opened_at`. The only sanctioned way to update the inner state from
  outside this module (Rule 2: state ownership).
  """
  @spec put_state(t(), Dashboard.state()) :: t()
  def put_state(%__MODULE__{} = payload, state) when is_map(state) do
    %{payload | state: state}
  end
end
