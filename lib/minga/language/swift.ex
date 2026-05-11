defmodule Minga.Language.Swift do
  @moduledoc "Swift language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :swift,
      label: "Swift",
      comment_token: "// ",
      extensions: ["swift"],
      icon: "\u{E755}",
      icon_color: 0xF05138,
      language_servers: [
        %ServerConfig{
          name: :sourcekit_lsp,
          command: "sourcekit-lsp",
          root_markers: ["Package.swift", "compile_commands.json"]
        }
      ],
      root_markers: ["Package.swift"]
    }
  end
end
