defmodule Minga.Language do
  @moduledoc """
  Unified per-language configuration struct.

  Every supported language is described by a single `%Language{}` struct
  that consolidates data previously spread across `Filetype`, `Comment`,
  `Formatter`, `LSP.ServerRegistry`, `Highlight.Grammar`, `Devicon`,
  `Modeline`, and `Project.Detector`.

  Language definitions live in `lib/minga/language/*.ex`, one module per
  language. Each module exports a `definition/0` function returning a
  `%Language{}` struct. The `Language.Registry` collects them at startup
  and provides O(1) lookups by name, extension, and filename.

  ## Adding a new language

  Create a new module under `Minga.Language.*` (e.g., `Minga.Language.Dart`)
  and return a `%Language{}` from `definition/0`. Register the module in
  `Minga.Language.Registry.@language_modules`. That's it: one file, one place.

  ## Extension languages

  Extensions register languages at runtime via
  `Minga.Language.Registry.register/1`, passing a `%Language{}` struct.
  Runtime registrations override built-in definitions for the same name.
  """

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
  Extensions call this to add language support at runtime.

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

  # ── Filetype detection delegates ──────────────────────────────────────────

  @doc "Detects a file's language atom from its path."
  @spec detect_filetype(String.t() | nil) :: atom()
  defdelegate detect_filetype(path), to: Minga.Language.Filetype, as: :detect

  @doc "Detects filetype using both path and first line content (shebang)."
  @spec detect_filetype_from_content(String.t(), String.t()) :: atom()
  defdelegate detect_filetype_from_content(path, first_line),
    to: Minga.Language.Filetype,
    as: :detect_from_content
end
