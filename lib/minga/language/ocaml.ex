defmodule Minga.Language.OCaml do
  @moduledoc "OCaml language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :ocaml,
      label: "OCaml",
      comment_token: "(* ",
      extensions: ["ml", "mli"],
      icon: "\u{E67F}",
      icon_color: 0xEC6813,
      grammar: "ocaml",
      language_servers: [
        %ServerConfig{
          name: :ocamllsp,
          command: "ocamllsp",
          root_markers: ["dune-project", "_opam", "opam"]
        }
      ],
      root_markers: ["dune-project"]
    }
  end
end
