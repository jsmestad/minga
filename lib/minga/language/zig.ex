defmodule Minga.Language.Zig do
  @moduledoc "Zig language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :zig,
      label: "Zig",
      comment_token: "// ",
      extensions: ["zig", "zon"],
      icon: "\u{E6A9}",
      icon_color: 0xF69A1B,
      grammar: "zig",
      formatter: "zig fmt --stdin",
      language_servers: [
        %ServerConfig{
          name: :zls,
          command: "zls",
          root_markers: ["build.zig", "build.zig.zon"]
        }
      ],
      root_markers: ["build.zig"],
      project_type: :zig
    }
  end
end
