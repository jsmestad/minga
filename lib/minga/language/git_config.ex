defmodule Minga.Language.GitConfig do
  @moduledoc "Git Config language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :gitconfig,
      label: "Git Config",
      comment_token: "# ",
      filenames: [".gitignore", ".gitattributes", ".gitmodules"],
      icon: "\u{E702}",
      icon_color: 0xF14C28
    }
  end
end
