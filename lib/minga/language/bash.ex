defmodule Minga.Language.Bash do
  @moduledoc "Shell language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :bash,
      label: "Shell",
      comment_token: "# ",
      extensions: ["sh", "bash", "zsh"],
      shebangs: ["bash", "sh", "zsh"],
      icon: "\u{E795}",
      icon_color: 0x89E051,
      grammar: "bash",
      language_servers: [
        %ServerConfig{
          name: :bash_language_server,
          command: "bash-language-server",
          args: ["start"]
        }
      ]
    }
  end
end
