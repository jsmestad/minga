defmodule Minga.Language.Scala do
  @moduledoc "Scala language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :scala,
      label: "Scala",
      comment_token: "// ",
      extensions: ["scala", "sbt", "sc"],
      icon: "\u{E737}",
      icon_color: 0xCC3E44,
      grammar: "scala"
    }
  end
end
