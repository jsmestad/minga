defmodule Minga.Language.GitIgnore do
  @moduledoc "Git ignore language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :gitignore,
      label: "Git Ignore",
      comment_token: "# ",
      filenames: [".gitignore", ".gitattributes"],
      icon: "\u{E702}",
      icon_color: 0xF14C28
    }
  end
end
