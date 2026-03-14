defmodule Minga.Language.JavaScript do
  @moduledoc "JavaScript language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :javascript,
      label: "JavaScript",
      comment_token: "// ",
      extensions: ["js", "mjs", "cjs"],
      shebangs: ["node"],
      icon: "\u{E781}",
      icon_color: 0xF7DF1E,
      grammar: "javascript",
      formatter: "prettier --stdin-filepath {file}",
      language_servers: [
        %ServerConfig{
          name: :typescript_language_server,
          command: "typescript-language-server",
          args: ["--stdio"],
          root_markers: ["package.json", "tsconfig.json", "jsconfig.json"]
        }
      ],
      root_markers: ["package.json"],
      project_type: :node
    }
  end
end
