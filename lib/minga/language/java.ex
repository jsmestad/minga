defmodule Minga.Language.Java do
  @moduledoc "Java language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :java,
      label: "Java",
      comment_token: "// ",
      extensions: ["java"],
      icon: "\u{E738}",
      icon_color: 0xCC3E44,
      grammar: "java"
    }
  end
end
