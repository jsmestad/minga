defmodule Minga.Language.Kotlin do
  @moduledoc "Kotlin language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :kotlin,
      label: "Kotlin",
      comment_token: "// ",
      extensions: ["kt", "kts"],
      icon: "\u{E634}",
      icon_color: 0x7F52FF,
      grammar: "kotlin",
      language_servers: [
        %ServerConfig{
          name: :kotlin_language_server,
          command: "kotlin-language-server",
          root_markers: ["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle"]
        }
      ],
      root_markers: ["pom.xml", "build.gradle"]
    }
  end
end
