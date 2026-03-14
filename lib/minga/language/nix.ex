defmodule Minga.Language.Nix do
  @moduledoc "Nix language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :nix,
      label: "Nix",
      comment_token: "# ",
      extensions: ["nix"],
      icon: "\u{F0313}",
      icon_color: 0x7EBAE4,
      grammar: "nix"
    }
  end
end
