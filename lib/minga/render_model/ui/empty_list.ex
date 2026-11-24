defmodule Minga.RenderModel.UI.EmptyList do
  @moduledoc """
  The empty-state anatomy every list surface shows when it has nothing in it (`docs/design/surfaces.md`, "Empty states and notices with actions").

  It says what happened (`title`, with the state `glyph` if there is one), why or what it means (`why`, one muted line), and what you can do next (`actions`, with `selected` preselected). Frontends draw it from `docs/design/anatomy.md` ("Empty state") and never author its copy.

  A picker carries only the header: its next steps are real result rows (picker items), so they move with `⌃J` / `⌃K`, run with `↩` and are clicked like any row. A panel without result rows (the file tree, git status) carries its next steps in `actions`.

  This is not the zero-buffers launchpad (`Minga.RenderModel.UI.EmptyState`), which is a separate surface with its own sections.
  """

  alias Minga.RenderModel.UI.EmptyList.Action

  @type t :: %__MODULE__{
          glyph: String.t(),
          title: String.t(),
          why: String.t(),
          actions: [Action.t()],
          selected: non_neg_integer()
        }

  @enforce_keys [:title]
  defstruct glyph: "", title: "", why: "", actions: [], selected: 0
end
