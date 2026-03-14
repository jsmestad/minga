defmodule Minga.Language.Yaml do
  @moduledoc "YAML language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :yaml,
      label: "YAML",
      comment_token: "# ",
      extensions: ["yaml", "yml"],
      icon: "\u{E6A8}",
      icon_color: 0xCB171E,
      grammar: "yaml",
      language_servers: [
        %ServerConfig{
          name: :yaml_language_server,
          command: "yaml-language-server",
          args: ["--stdio"]
        }
      ]
    }
  end
end
