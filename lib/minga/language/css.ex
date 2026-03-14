defmodule Minga.Language.Css do
  @moduledoc "CSS language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :css,
      label: "CSS",
      comment_token: "/* ",
      extensions: ["css"],
      icon: "\u{E749}",
      icon_color: 0x563D7C,
      grammar: "css",
      language_servers: [
        %ServerConfig{
          name: :vscode_css_languageserver,
          command: "vscode-css-language-server",
          args: ["--stdio"],
          root_markers: ["package.json"]
        }
      ]
    }
  end
end
