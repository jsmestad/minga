defmodule Minga.Language.ObjectiveC do
  @moduledoc "Objective-C language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :objective_c,
      label: "Objective-C",
      comment_token: "// ",
      extensions: ["m", "mm"],
      icon: "\u{F179}",
      icon_color: 0xA8B9CC,
      grammar: "objc",
      formatter: "clang-format",
      language_servers: [
        %ServerConfig{
          name: :clangd,
          command: "clangd",
          root_markers: ["compile_commands.json", ".clangd", "Makefile"]
        }
      ],
      root_markers: ["compile_commands.json", ".clangd", "Makefile", ".xcodeproj"],
      project_type: :c
    }
  end
end
