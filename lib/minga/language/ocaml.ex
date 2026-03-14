defmodule Minga.Language.OCaml do
  @moduledoc "OCaml language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :ocaml,
      label: "OCaml",
      comment_token: "(* ",
      extensions: ["ml", "mli"],
      icon: "\u{E67F}",
      icon_color: 0xEC6813,
      grammar: "ocaml"
    }
  end
end
