defmodule Minga.Language.Elixir do
  @moduledoc "Elixir language definition"

  alias Minga.Language
  alias Minga.Language.BlockPair
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
          name: :expert,
          command: "expert",
          args: ["--stdio"],
          root_markers: ["mix.exs"]
        }
      ],
      root_markers: ["mix.exs", "mix.lock"],
      project_type: :mix
    }
  end

  @doc "Returns Insert-mode block auto-close metadata for Elixir."
  @spec block_pairs() :: [BlockPair.t()]
  def block_pairs do
    [
      BlockPair.new("do", "end", :line_suffix),
      BlockPair.new("fn", "end", :line_suffix)
    ]
  end
end
