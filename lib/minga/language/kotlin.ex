defmodule Minga.Language.Kotlin do
  @moduledoc "Kotlin language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :kotlin,
      label: "Kotlin",
      comment_token: "// ",
      extensions: ["kt", "kts"],
      icon: "\u{E634}",
      icon_color: 0x7F52FF,
      grammar: "kotlin"
    }
  end
end
