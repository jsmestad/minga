defmodule Minga.Language.C do
  @moduledoc "C language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :c,
      label: "C",
      comment_token: "// ",
      extensions: ["c", "h"],
      icon: "\u{E61E}",
      icon_color: 0x599EFF,
      grammar: "c",
      formatter: "clang-format",
      language_servers: [
        %ServerConfig{
          name: :clangd,
          command: "clangd",
          root_markers: ["compile_commands.json", "CMakeLists.txt", ".clangd"]
        }
      ]
    }
  end
end
