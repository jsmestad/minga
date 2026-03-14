defmodule Minga.Language.Swift do
  @moduledoc "Swift language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :swift,
      label: "Swift",
      comment_token: "// ",
      extensions: ["swift"],
      icon: "\u{E755}",
      icon_color: 0xF05138
    }
  end
end
