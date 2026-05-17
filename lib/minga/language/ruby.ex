defmodule Minga.Language.Ruby do
  @moduledoc "Ruby language definition"

  alias Minga.Language
  alias Minga.Language.BlockPair
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :ruby,
      label: "Ruby",
      comment_token: "# ",
      extensions: ["rb", "rake", "gemspec"],
      filenames: ["Gemfile", "Rakefile", "Brewfile"],
      shebangs: ["ruby"],
      icon: "\u{E739}",
      icon_color: 0xCC342D,
      grammar: "ruby",
      language_servers: [
        %ServerConfig{
          name: :solargraph,
          command: "solargraph",
          args: ["stdio"],
          root_markers: ["Gemfile", ".solargraph.yml"]
        }
      ],
      root_markers: ["Gemfile"],
      project_type: :ruby
    }
  end

  @doc "Returns Insert-mode block auto-close metadata for Ruby."
  @spec block_pairs() :: [BlockPair.t()]
  def block_pairs do
    [
      BlockPair.new("def", "end", :line_head),
      BlockPair.new("class", "end", :line_head),
      BlockPair.new("module", "end", :line_head),
      BlockPair.new("if", "end", :line_head),
      BlockPair.new("do", "end", :line_suffix)
    ]
  end
end
