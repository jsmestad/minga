defmodule Minga.Language do
  @moduledoc """
  Unified per-language configuration struct.

  Every supported language is described by a single `%Language{}` struct
  that consolidates data previously spread across `Filetype`, `Comment`,
  `Formatter`, `LSP.ServerRegistry`, `Highlight.Grammar`, `Devicon`,
  `Modeline`, and `Project.Detector`.

  Language definitions live in modules that export a `definition/0` function returning a `%Language{}` struct. Bundled definitions are grouped into language pack extensions under `Minga.Extensions.LanguagePacks`, and third-party packs register the same struct shape through `Minga.Language.Registry.register/2`.

  ## Adding a new language

  Create a language module inside a pack, return a `%Language{}` from `definition/0`, and add that module to the pack's `language_modules/0` list. Removing the pack's registry source removes the whole language record, so the language name, filetypes, shebangs, devicon, grammar metadata, formatter, and LSP defaults go away together.

  ## Extension languages

  Extensions register languages at runtime via `Minga.Language.Registry.register/2`, passing a `%Language{}` struct and a `{:extension, name}` source.
  """

  alias Minga.Language.BlockPair
  alias Minga.LSP.ServerConfig

  @typedoc "A per-language configuration."
  @type t :: %__MODULE__{
          name: atom(),
          label: String.t(),
          comment_token: String.t(),
          extensions: [String.t()],
          filenames: [String.t()],
          shebangs: [String.t()],
          icon: String.t() | nil,
          icon_color: non_neg_integer() | nil,
          tab_width: pos_integer(),
          indent_with: :spaces | :tabs,
          grammar: String.t() | nil,
          formatter: String.t() | nil,
          language_servers: [ServerConfig.t()],
          root_markers: [String.t()],
          project_type: atom() | nil
        }

  @enforce_keys [:name, :label, :comment_token]
  defstruct [
    :name,
    :label,
    :comment_token,
    :grammar,
    :formatter,
    :project_type,
    :icon,
    :icon_color,
    extensions: [],
    filenames: [],
    shebangs: [],
    tab_width: 2,
    indent_with: :spaces,
    language_servers: [],
    root_markers: []
  ]

  # ── Language registration ─────────────────────────────────────────────────

  @doc """
  Registers a new language with Minga.

  Compiles the tree-sitter grammar sources, loads them into the parser,
  sends highlight/injection queries, and registers filetype mappings.
  Compilation and setup failures are reported synchronously; the parser-side
  load response is asynchronous, so callers decide whether to fail the
  extension or continue without highlighting.

  `name` is the language identifier (e.g., `"org"`).
  `source_dir` is the path containing the grammar's `parser.c` and
  optionally `scanner.c`.

  ## Options

  - `:highlights` - path to a `highlights.scm` query file
  - `:injections` - path to an `injections.scm` query file
  - `:filetype_extensions` - list of file extensions to map (e.g., `[".org"]`)
  - `:filetype_filenames` - list of exact filenames to map (e.g., `["Orgfile"]`)
  - `:filetype_atom` - the filetype atom (e.g., `:org`)

  ## Example

      Minga.Language.register("org", "/path/to/tree-sitter-org/src",
        highlights: "/path/to/queries/org/highlights.scm",
        filetype_extensions: [".org"],
        filetype_atom: :org
      )
  """
  @spec register(String.t(), String.t(), [Minga.Language.TreeSitter.register_opt()]) ::
          :ok | {:error, String.t()}
  defdelegate register(name, source_dir, opts \\ []),
    to: Minga.Language.TreeSitter,
    as: :register_grammar

  # ── Language lookup ──────────────────────────────────────────────────────

  @doc "Returns the language definition for a name atom (e.g., `:elixir`), or nil."
  @spec get(atom()) :: t() | nil
  defdelegate get(name), to: Minga.Language.Registry

  @doc "Returns language-owned block auto-close metadata for a language name."
  @spec block_pairs(atom()) :: [BlockPair.t()]
  defdelegate block_pairs(name), to: BlockPair, as: :for_language

  @doc "Returns all registered language definitions."
  @spec all() :: [t()]
  defdelegate all, to: Minga.Language.Registry

  # ── Filetype detection ─────────────────────────────────────────────────────

  @doc "Detects a file's language atom from its path."
  @spec detect_filetype(String.t() | nil) :: atom()
  defdelegate detect_filetype(path), to: Minga.Language.Filetype, as: :detect

  @doc "Detects filetype using both path and first line content (shebang)."
  @spec detect_filetype_from_content(String.t(), String.t()) :: atom()
  defdelegate detect_filetype_from_content(path, first_line),
    to: Minga.Language.Filetype,
    as: :detect_from_content
end
