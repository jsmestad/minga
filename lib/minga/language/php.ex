defmodule Minga.Language.Php do
  @moduledoc "PHP language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :php,
      label: "PHP",
      comment_token: "// ",
      extensions: ["php", "phtml"],
      icon: "\u{E73D}",
      icon_color: 0x777BB3,
      grammar: "php",
      language_servers: [
        %ServerConfig{
          name: :intelephense,
          command: "intelephense",
          args: ["--stdio"],
          root_markers: ["composer.json", ".phpstorm.meta.php"]
        }
      ],
      root_markers: ["composer.json"]
    }
  end
end
