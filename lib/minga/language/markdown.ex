defmodule Minga.Language.Markdown do
  @moduledoc "Markdown language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :markdown,
      label: "Markdown",
      comment_token: "<!-- ",
      extensions: ["md", "markdown"],
      icon: "\u{E73E}",
      icon_color: 0x519ABA,
      grammar: "markdown"
    }
  end
end
