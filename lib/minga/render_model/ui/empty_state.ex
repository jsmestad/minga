defmodule Minga.RenderModel.UI.EmptyState do
  @moduledoc """
  Semantic model for the zero-buffers launchpad surface (#2689).

  Sections are data-driven: the session section exists only when a saved
  session has entries, recents only when the project has recent files, and
  the start section always. Chords are resolved from the live keymap by the
  builder, never hardcoded, so hints stay truthful to user overrides.

  Frontends own the layout (SwiftUI column with the logo watermark, TUI
  centered block from the shared chrome primitives); this struct carries
  only content and focus. Activation semantics live on the BEAM: frontends
  echo `empty_state_activate` with an item id.
  """

  alias Minga.RenderModel.UI.EmptyState.Item
  alias Minga.RenderModel.UI.EmptyState.Section

  @type t :: %__MODULE__{
          visible?: boolean(),
          crashed?: boolean(),
          focused_id: String.t() | nil,
          version: String.t(),
          sections: [Section.t()]
        }

  defstruct visible?: false,
            crashed?: false,
            focused_id: nil,
            version: "",
            sections: []

  @doc "Returns every item across sections in display order."
  @spec items(t()) :: [Item.t()]
  def items(%__MODULE__{sections: sections}) do
    Enum.flat_map(sections, & &1.items)
  end
end
