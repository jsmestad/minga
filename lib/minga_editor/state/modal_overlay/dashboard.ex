defmodule MingaEditor.State.ModalOverlay.Dashboard do
  @moduledoc """
  Modal-overlay payload for the dashboard home screen.

  Wraps the existing `MingaEditor.Dashboard.state()` map (cursor + items)
  with the metadata every ModalOverlay variant carries. The dashboard is
  global UX, so `owner` defaults to `:global`.
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
end
