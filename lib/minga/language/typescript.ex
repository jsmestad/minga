defmodule Minga.Language.TypeScript do
  @moduledoc "TypeScript language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :typescript,
      label: "TypeScript",
      comment_token: "// ",
      extensions: ["ts", "mts", "cts"],
      icon: "\u{E628}",
      icon_color: 0x3178C6,
      grammar: "typescript",
      formatter: "prettier --stdin-filepath {file}",
      language_servers: [
        %ServerConfig{
          name: :typescript_language_server,
          command: "typescript-language-server",
          args: ["--stdio"],
          root_markers: ["package.json", "tsconfig.json"]
        }
      ]
    }
  end
end
