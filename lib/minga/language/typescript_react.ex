defmodule Minga.Language.TypeScriptReact do
  @moduledoc "TSX language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :typescript_react,
      label: "TSX",
      comment_token: "// ",
      extensions: ["tsx"],
      icon: "\u{E7BA}",
      icon_color: 0x3178C6,
      grammar: "tsx",
      formatter: "prettier --stdin-filepath {file}"
    }
  end
end
