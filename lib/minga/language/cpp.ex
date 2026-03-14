defmodule Minga.Language.Cpp do
  @moduledoc "C++ language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :cpp,
      label: "C++",
      comment_token: "// ",
      extensions: ["cpp", "cc", "cxx", "hpp"],
      icon: "\u{E61D}",
      icon_color: 0xF34B7D,
      grammar: "cpp",
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
