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
