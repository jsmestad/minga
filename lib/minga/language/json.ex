defmodule Minga.Language.Json do
  @moduledoc "JSON language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :json,
      label: "JSON",
      comment_token: "// ",
      extensions: ["json", "jsonc"],
      icon: "\u{E60B}",
      icon_color: 0xCBCB41,
      grammar: "json",
      language_servers: [
        %ServerConfig{
          name: :vscode_json_languageserver,
          command: "vscode-json-language-server",
          args: ["--stdio"]
        }
      ]
    }
  end
end
