defmodule Minga.RenderModel.Window.DocumentHighlight do
  @moduledoc """
  A document highlight range in display coordinates for the GUI protocol.

  Sent as part of `gui_window_content` (0x80). The kind distinguishes LSP references and the transient source of a hover.
  """

  @enforce_keys [:start_row, :start_col, :end_row, :end_col, :kind]
  defstruct [:start_row, :start_col, :end_row, :end_col, :kind]

  @typedoc "LSP reference kinds and an editor-local hover source."
  @type kind :: :text | :read | :write | :hover

  @type t :: %__MODULE__{
          start_row: non_neg_integer(),
          start_col: non_neg_integer(),
          end_row: non_neg_integer(),
          end_col: non_neg_integer(),
          kind: kind()
        }
end
