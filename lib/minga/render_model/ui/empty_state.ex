defmodule Minga.RenderModel.UI.EmptyState do
  @moduledoc """
  Semantic model for the project home, `*home*` (#4056), shown in the active window.

  The header says where you are: `title` (the project or folder name, or "Minga" outside a project), `path` (home-relative), and `status`, one line with the branch and change count, or why there is no project. `note` is an optional muted second line. Sections follow in display order: recent files or recent projects, Minga's tasks, and the next actions. Chords are resolved from the live keymap by the builder, never hardcoded, so hints stay truthful to user overrides.

  Frontends own the layout (a left-aligned resting view on both); this struct carries only content and focus. Activation semantics live on the BEAM: frontends echo `empty_state_activate` with an item id.
  """

  alias Minga.RenderModel.UI.EmptyState.Item
  alias Minga.RenderModel.UI.EmptyState.Section

  @type t :: %__MODULE__{
          visible?: boolean(),
          focused_id: String.t() | nil,
          title: String.t(),
          path: String.t(),
          status: String.t(),
          note: String.t(),
          sections: [Section.t()]
        }

  defstruct visible?: false,
            focused_id: nil,
            title: "",
            path: "",
            status: "",
            note: "",
            sections: []

  @doc "Returns every item across sections in display order."
  @spec items(t()) :: [Item.t()]
  def items(%__MODULE__{sections: sections}) do
    Enum.flat_map(sections, & &1.items)
  end
end
