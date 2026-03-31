defmodule MingaEditor.Input.GitStatus.TuiState do
  @moduledoc """
  Internal state struct for the TUI git status panel.

  Tracks cursor position, collapsed sections, and the flattened list of
  display entries (section headers + file rows) used for navigation and
  rendering.
  """

  @enforce_keys [:cursor_index, :collapsed, :flat_entries, :entries]
  defstruct [:cursor_index, :collapsed, :flat_entries, :entries]

  @type flat_entry ::
          {:section_header, atom(), non_neg_integer()}
          | {:file, atom(), Minga.Git.StatusEntry.t()}

  @type t :: %__MODULE__{
          cursor_index: non_neg_integer(),
          collapsed: %{atom() => true},
          flat_entries: [flat_entry()],
          entries: [Minga.Git.StatusEntry.t()]
        }
end
