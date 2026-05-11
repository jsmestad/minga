defmodule Minga.Language.Java do
  @moduledoc "Java language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :java,
      label: "Java",
      comment_token: "// ",
      extensions: ["java"],
      icon: "\u{E738}",
      icon_color: 0xCC3E44,
      grammar: "java",
      language_servers: [
        %ServerConfig{
          name: :jdtls,
          command: "jdtls",
          root_markers: ["pom.xml", "build.gradle", "build.gradle.kts", ".classpath"]
        }
      ],
      root_markers: ["pom.xml", "build.gradle"]
    }
  end
end
