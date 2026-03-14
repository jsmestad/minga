defmodule Minga.Language.Go do
  @moduledoc "Go language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :go,
      label: "Go",
      comment_token: "// ",
      extensions: ["go"],
      icon: "\u{E626}",
      icon_color: 0x00ADD8,
      tab_width: 4,
      indent_with: :tabs,
      grammar: "go",
      formatter: "gofmt",
      language_servers: [
        %ServerConfig{
          name: :gopls,
          command: "gopls",
          root_markers: ["go.mod", "go.sum"]
        }
      ],
      root_markers: ["go.mod"],
      project_type: :go
    }
  end
end
