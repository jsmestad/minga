defmodule Minga.Language.Scss do
  @moduledoc "SCSS language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :scss,
      label: "SCSS",
      comment_token: "// ",
      extensions: ["scss", "sass"],
      icon: "\u{E74B}",
      icon_color: 0xCD6799,
      grammar: "scss"
    }
  end
end
