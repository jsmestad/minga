defmodule Minga.Language.Dart do
  @moduledoc "Dart language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :dart,
      label: "Dart",
      comment_token: "// ",
      extensions: ["dart"],
      icon: "\u{E798}",
      icon_color: 0x03589C,
      grammar: "dart",
      language_servers: [
        %ServerConfig{
          name: :dart_language_server,
          command: "dart",
          args: ["language-server"],
          root_markers: ["pubspec.yaml", ".dart_tool"]
        }
      ],
      root_markers: ["pubspec.yaml"]
    }
  end
end
