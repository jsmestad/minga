defmodule Minga.Language.Elixir do
  @moduledoc "Elixir language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :elixir,
      label: "Elixir",
      comment_token: "# ",
      extensions: ["ex", "exs"],
      filenames: ["mix.lock"],
      shebangs: ["elixir"],
      icon: "\u{E62D}",
      icon_color: 0x9B59B6,
      grammar: "elixir",
      formatter: "mix format --stdin-filename {file} -",
      language_servers: [
        %ServerConfig{
          name: :lexical,
          command: "lexical",
          root_markers: ["mix.exs"]
        }
      ],
      root_markers: ["mix.exs", "mix.lock"],
      project_type: :mix
    }
  end
end
