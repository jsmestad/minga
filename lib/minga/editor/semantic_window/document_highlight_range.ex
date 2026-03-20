defmodule Minga.Editor.SemanticWindow.DocumentHighlightRange do
  @moduledoc """
  A document highlight range in display coordinates for the GUI protocol.

  Sent as part of the `gui_window_content` (0x80) opcode. The kind field
  distinguishes text, read, and write references for distinct styling.
  """

  @enforce_keys [:start_row, :start_col, :end_row, :end_col, :kind]
  defstruct [:start_row, :start_col, :end_row, :end_col, :kind]

  @typedoc "Highlight kind matching the LSP spec."
  @type kind :: :text | :read | :write

  @type t :: %__MODULE__{
          start_row: non_neg_integer(),
          start_col: non_neg_integer(),
          end_row: non_neg_integer(),
          end_col: non_neg_integer(),
          kind: kind()
        }
end
