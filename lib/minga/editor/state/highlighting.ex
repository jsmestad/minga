defmodule Minga.Editor.State.Highlighting do
  @moduledoc """
  Groups syntax-highlighting fields from EditorState.

  Tracks the current highlight state, a monotonic version counter for
  invalidation, and a per-buffer cache of highlight data.
  """

  alias Minga.Highlight

  @type t :: %__MODULE__{
          current: Highlight.t(),
          version: non_neg_integer(),
          cache: %{pid() => Highlight.t()}
        }

  defstruct current: Highlight.new(),
            version: 0,
            cache: %{}
end
