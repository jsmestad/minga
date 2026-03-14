defmodule Minga.Language.Haskell do
  @moduledoc "Haskell language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :haskell,
      label: "Haskell",
      comment_token: "-- ",
      extensions: ["hs", "lhs"],
      icon: "\u{E777}",
      icon_color: 0x5E5086,
      grammar: "haskell"
    }
  end
end
