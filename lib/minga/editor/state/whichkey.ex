defmodule Minga.Editor.State.WhichKey do
  @moduledoc """
  Groups which-key popup fields from EditorState.

  Tracks the current trie node (for leader-key navigation), the pending
  timeout reference, and whether the popup should be displayed.
  """

  @type t :: %__MODULE__{
          node: Minga.Keymap.Bindings.node_t() | nil,
          timer: Minga.WhichKey.timer_ref() | nil,
          show: boolean(),
          prefix_keys: [String.t()],
          page: non_neg_integer()
        }

  defstruct node: nil,
            timer: nil,
            show: false,
            prefix_keys: [],
            page: 0

  @doc "Returns a cleared (reset) which-key state."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = wk) do
    if wk.timer, do: Minga.WhichKey.cancel_timeout(wk.timer)
    %__MODULE__{}
  end
end
