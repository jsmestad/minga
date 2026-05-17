defmodule Minga.Language.Bash do
  @moduledoc "Shell language definition"

  alias Minga.Language
  alias Minga.Language.BlockPair
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

  @doc "Returns Insert-mode block auto-close metadata for shell scripts."
  @spec block_pairs() :: [BlockPair.t()]
  def block_pairs do
    [
      BlockPair.new("if", "fi", :line_head),
      BlockPair.new("do", "done", :line_suffix),
      BlockPair.new("case", "esac", :line_head)
    ]
  end
end
