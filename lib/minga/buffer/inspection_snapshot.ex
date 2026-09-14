defmodule Minga.Buffer.InspectionSnapshot do
  @moduledoc "Bounded, coherent buffer metadata and viewport text for semantic inspection."

  @enforce_keys [
    :version,
    :line_count,
    :cursor,
    :cursor_line_text,
    :display_name,
    :viewport_start,
    :viewport_lines
  ]
  defstruct [
    :version,
    :line_count,
    :cursor,
    :cursor_line_text,
    :display_name,
    :file_path,
    :viewport_start,
    :viewport_lines
  ]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          line_count: pos_integer(),
          cursor: Minga.Buffer.position(),
          cursor_line_text: String.t(),
          display_name: String.t(),
          file_path: String.t() | nil,
          viewport_start: non_neg_integer(),
          viewport_lines: [String.t()]
        }
end
