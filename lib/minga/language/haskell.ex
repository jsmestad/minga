defmodule Minga.Language.Haskell do
  @moduledoc "Haskell language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :haskell,
      label: "Haskell",
      comment_token: "-- ",
      extensions: ["hs", "lhs"],
      icon: "\u{E777}",
      icon_color: 0x5E5086,
      grammar: "haskell",
      language_servers: [
        %ServerConfig{
          name: :haskell_language_server,
          command: "haskell-language-server-wrapper",
          args: ["--lsp"],
          root_markers: ["cabal.project", "stack.yaml", "hie.yaml"]
        }
      ],
      root_markers: ["cabal.project", "stack.yaml"]
    }
  end
end
