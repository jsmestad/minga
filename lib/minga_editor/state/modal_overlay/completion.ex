defmodule MingaEditor.State.ModalOverlay.Completion do
  @moduledoc """
  Modal-overlay payload for the completion menu.

  The completion menu is logically per-tab: it tracks the cursor position of
  the buffer that triggered it. The `owner` field carries the tab identifier
  so a future tab-switch hook can auto-dismiss completion that no longer
  belongs to the active tab.
  """

  alias Minga.Editing.Completion

  @typedoc """
  Identifier of the tab that triggered completion.

  Tab IDs are the keys of `MingaEditor.State.TabBar`'s tab map. We accept
  any term so callers do not need to depend on TabBar's id type directly.
  """
  @type owner :: term()

  @type t :: %__MODULE__{
          completion: Completion.t(),
          owner: owner(),
          opened_at: integer()
        }

  @enforce_keys [:completion, :owner]
  defstruct [:completion, :owner, opened_at: 0]

  @doc "Builds a completion payload bound to `owner` (typically a tab id)."
  @spec new(Completion.t(), owner(), keyword()) :: t()
  def new(%Completion{} = completion, owner, opts \\ []) do
    %__MODULE__{
      completion: completion,
      owner: owner,
      opened_at: Keyword.get(opts, :opened_at, System.monotonic_time(:millisecond))
    }
  end
end
