defmodule Minga.Extensions.LanguagePacks.Bundled do
  @moduledoc """
  Bundled language catalog shipped with normal Minga builds.

  The language definitions still live in `Minga.Language.*` modules. This pack owns how those modules reach the runtime registry, which lets reload and disable paths remove the whole catalog without leaving stale filetype, shebang, devicon, grammar, or LSP data behind.
  """

  use Minga.Extension

  @language_modules [
    Minga.Language.Bash,
    Minga.Language.C,
    Minga.Language.Clojure,
    Minga.Language.Conf,
    Minga.Language.Cpp,
    Minga.Language.CSharp,
    Minga.Language.Css,
    Minga.Language.Csv,
    Minga.Language.Dart,
    Minga.Language.Diff,
    Minga.Language.Dockerfile,
    Minga.Language.EditorConfig,
    Minga.Language.Elixir,
    Minga.Language.EmacsLisp,
    Minga.Language.Erlang,
    Minga.Language.Fish,
    Minga.Language.GitConfig,
    Minga.Language.GitIgnore,
    Minga.Language.Gleam,
    Minga.Language.Go,
    Minga.Language.GraphQL,
    Minga.Language.Haskell,
    Minga.Language.Hcl,
    Minga.Language.Heex,
    Minga.Language.Html,
    Minga.Language.Ini,
    Minga.Language.Java,
    Minga.Language.JavaScript,
    Minga.Language.JavaScriptReact,
    Minga.Language.Json,
    Minga.Language.Kotlin,
    Minga.Language.Lfe,
    Minga.Language.Lua,
    Minga.Language.Make,
    Minga.Language.Markdown,
    Minga.Language.Nix,
    Minga.Language.ObjectiveC,
    Minga.Language.OCaml,
    Minga.Language.Perl,
    Minga.Language.Php,
    Minga.Language.Protobuf,
    Minga.Language.Python,
    Minga.Language.R,
    Minga.Language.Ruby,
    Minga.Language.Rust,
    Minga.Language.Scala,
    Minga.Language.Scss,
    Minga.Language.Sql,
    Minga.Language.Swift,
    Minga.Language.Text,
    Minga.Language.Toml,
    Minga.Language.TypeScript,
    Minga.Language.TypeScriptReact,
    Minga.Language.Vim,
    Minga.Language.Xml,
    Minga.Language.Yaml,
    Minga.Language.Zig
  ]

  @impl true
  @spec name() :: atom()
  def name, do: :minga_language_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "Bundled Minga language definitions"

  @impl true
  @spec version() :: String.t()
  def version, do: "0.1.0"

  @impl true
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(_config) do
    case Minga.Extensions.LanguagePacks.register_pack(__MODULE__) do
      :ok -> {:ok, %{languages: length(@language_modules)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the language definition modules owned by this pack."
  @spec language_modules() :: [module()]
  def language_modules, do: @language_modules
end
