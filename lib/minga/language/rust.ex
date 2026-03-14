defmodule Minga.Language.Rust do
  @moduledoc "Rust language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :rust,
      label: "Rust",
      comment_token: "// ",
      extensions: ["rs"],
      icon: "\u{E7A8}",
      icon_color: 0xDEA584,
      grammar: "rust",
      formatter: "rustfmt --edition 2021",
      language_servers: [
        %ServerConfig{
          name: :rust_analyzer,
          command: "rust-analyzer",
          root_markers: ["Cargo.toml"]
        }
      ],
      root_markers: ["Cargo.toml"],
      project_type: :cargo
    }
  end
end
