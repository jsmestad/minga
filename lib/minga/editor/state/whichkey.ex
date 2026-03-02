defmodule Minga.Editor.State.WhichKey do
  @moduledoc """
  Groups which-key popup fields from EditorState.

  Tracks the current trie node (for leader-key navigation), the pending
  timeout reference, and whether the popup should be displayed.
  """

  @type t :: %__MODULE__{
          node: Minga.Keymap.Trie.node_t() | nil,
          timer: Minga.WhichKey.timer_ref() | nil,
          show: boolean()
        }

  defstruct node: nil,
            timer: nil,
            show: false

  @doc "Returns a cleared (reset) which-key state."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = wk) do
    if wk.timer, do: Minga.WhichKey.cancel_timeout(wk.timer)
    %__MODULE__{}
  end
end
