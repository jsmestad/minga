defmodule Minga.RenderModel.UI.FileTree.Row do
  @moduledoc false

  alias Minga.RenderModel.UI.FileTree.Editing
  alias Minga.RenderModel.UI.FileTree.Flags

  @type git_status :: :modified | :staged | :untracked | :conflict | :renamed | :deleted
  @type diagnostics ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          name: String.t(),
          icon: String.t(),
          flags: Flags.t(),
          git_status: git_status() | nil,
          diagnostics: diagnostics(),
          depth: non_neg_integer(),
          guides: [boolean()],
          editing: Editing.t() | nil
        }

  @enforce_keys [:id, :path, :name, :icon, :depth, :guides]
  defstruct id: "",
            path: "",
            name: "",
            icon: "",
            flags: %Flags{},
            git_status: nil,
            diagnostics: {0, 0, 0, 0},
            depth: 0,
            guides: [],
            editing: nil
end
