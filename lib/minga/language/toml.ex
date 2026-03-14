defmodule Minga.Language.Toml do
  @moduledoc "TOML language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :toml,
      label: "TOML",
      comment_token: "# ",
      extensions: ["toml"],
      icon: "\u{E615}",
      icon_color: 0x9C4221,
      grammar: "toml"
    }
  end
end
