defmodule Minga.Language.R do
  @moduledoc "R language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :r,
      label: "R",
      comment_token: "# ",
      extensions: ["r", "rmd"],
      icon: "\u{E68A}",
      icon_color: 0x276DC3,
      grammar: "r"
    }
  end
end
