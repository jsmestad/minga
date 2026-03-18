defmodule Minga.Language.Clojure do
  @moduledoc "Clojure language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :clojure,
      label: "Clojure",
      comment_token: "; ",
      extensions: ["clj", "cljs", "cljc", "edn"],
      filenames: ["deps.edn", "project.clj", "build.clj"],
      icon: "\u{E76A}",
      icon_color: 0x63B132,
      grammar: "clojure",
      language_servers: [
        %ServerConfig{
          name: :clojure_lsp,
          command: "clojure-lsp",
          root_markers: ["deps.edn", "project.clj", "build.clj"]
        }
      ],
      root_markers: ["deps.edn", "project.clj", "build.clj"],
      project_type: :clojure
    }
  end
end
