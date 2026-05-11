defmodule Minga.Language.Gleam do
  @moduledoc "Gleam language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :gleam,
      label: "Gleam",
      comment_token: "// ",
      extensions: ["gleam"],
      icon: "\u{F0E7}",
      icon_color: 0xFFAFEF,
      grammar: "gleam",
      language_servers: [
        %ServerConfig{
          name: :gleam_lsp,
          command: "gleam",
          args: ["lsp"],
          root_markers: ["gleam.toml"]
        }
      ],
      root_markers: ["gleam.toml"]
    }
  end
end
