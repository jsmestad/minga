defmodule Minga.Language.Scala do
  @moduledoc "Scala language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :scala,
      label: "Scala",
      comment_token: "// ",
      extensions: ["scala", "sbt", "sc"],
      icon: "\u{E737}",
      icon_color: 0xCC3E44,
      grammar: "scala",
      language_servers: [
        %ServerConfig{
          name: :metals,
          command: "metals",
          root_markers: ["build.sbt", "build.sc"]
        }
      ],
      root_markers: ["build.sbt", "build.sc"]
    }
  end
end
