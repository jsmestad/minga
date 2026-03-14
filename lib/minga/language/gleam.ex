defmodule Minga.Language.Gleam do
  @moduledoc "Gleam language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :gleam,
      label: "Gleam",
      comment_token: "// ",
      extensions: ["gleam"],
      icon: "\u{F0E7}",
      icon_color: 0xFFAFEF,
      grammar: "gleam"
    }
  end
end
