defmodule MingaEditor.Input.GitStatus.TuiState do
  @moduledoc """
  Internal state struct for the TUI git status panel.

  Tracks cursor position, collapsed sections, and the flattened list of
  display entries (section headers + file rows) used for navigation and
  rendering.

  Additional state: discard_confirmation and amend_mode for pending operations.
  """

  @enforce_keys [:cursor_index, :collapsed, :flat_entries, :entries]
  defstruct [
    :cursor_index,
    :collapsed,
    :flat_entries,
    :entries,
    discard_confirmation: nil,
    amend_mode: false
  ]

  @type flat_entry ::
          {:section_header, atom(), non_neg_integer()}
          | {:file, atom(), Minga.Git.StatusEntry.t()}

  @type discard_confirmation ::
          {Minga.Git.StatusEntry.t(), String.t()} | nil

  @type t :: %__MODULE__{
          cursor_index: non_neg_integer(),
          collapsed: %{atom() => true},
          flat_entries: [flat_entry()],
          entries: [Minga.Git.StatusEntry.t()],
          discard_confirmation: discard_confirmation(),
          amend_mode: boolean()
        }
end
