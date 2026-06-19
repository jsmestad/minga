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
          icon_color: non_neg_integer(),
          flags: Flags.t(),
          git_status: git_status() | nil,
          diagnostics: diagnostics(),
          heat_level: 0..4 | nil,
          depth: non_neg_integer(),
          guides: [boolean()],
          editing: Editing.t() | nil
        }

  # Default icon tint for unknown filetypes; matches `Minga.Language.Devicon`'s default.
  @default_icon_color 0x6D8086

  @enforce_keys [:id, :path, :name, :icon, :depth, :guides]
  defstruct id: "",
            path: "",
            name: "",
            icon: "",
            icon_color: @default_icon_color,
            flags: %Flags{},
            git_status: nil,
            diagnostics: {0, 0, 0, 0},
            heat_level: nil,
            depth: 0,
            guides: [],
            editing: nil
end
