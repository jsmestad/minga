defmodule Minga.Language.Html do
  @moduledoc "HTML language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :html,
      label: "HTML",
      comment_token: "<!-- ",
      extensions: ["html", "htm"],
      icon: "\u{E736}",
      icon_color: 0xE34C26,
      grammar: "html",
      language_servers: [
        %ServerConfig{
          name: :vscode_html_languageserver,
          command: "vscode-html-language-server",
          args: ["--stdio"],
          root_markers: ["package.json"]
        }
      ]
    }
  end
end
