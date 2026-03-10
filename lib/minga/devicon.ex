defmodule Minga.Devicon do
  @moduledoc """
  Maps filetypes and special buffer types to Nerd Font icons and colors.

  A pure functional module with pattern-matched clauses. No GenServer, no
  ETS, no config. The icon/color data is compiled into the module. This
  mirrors how `Minga.Filetype` works.

  Used by the tab bar, file tree, buffer picker, and anywhere else that
  displays a filename alongside a visual indicator.
  """

  @type filetype :: atom()

  @doc "Returns the Nerd Font icon for the given filetype."
  @spec icon(filetype()) :: String.t()
  def icon(ft), do: elem(icon_and_color(ft), 0)

  @doc "Returns the 24-bit RGB color for the given filetype."
  @spec color(filetype()) :: non_neg_integer()
  def color(ft), do: elem(icon_and_color(ft), 1)

  @doc "Returns `{icon, color}` for the given filetype."
  @spec icon_and_color(filetype()) :: {String.t(), non_neg_integer()}

  # ── Languages ──────────────────────────────────────────────────────────────

  # Elixir (nf-custom-elixir)
  def icon_and_color(:elixir), do: {"\u{E62D}", 0x9B59B6}
  # Erlang (nf-dev-erlang)
  def icon_and_color(:erlang), do: {"\u{E7B1}", 0xA90533}
  # HEEx (same as Elixir)
  def icon_and_color(:heex), do: {"\u{E62D}", 0x9B59B6}
  # LFE (Erlang family)
  def icon_and_color(:lfe), do: {"\u{E7B1}", 0xA90533}
  # Zig (nf-seti-zig)
  def icon_and_color(:zig), do: {"\u{E6A9}", 0xF69A1B}
  # Rust (nf-dev-rust)
  def icon_and_color(:rust), do: {"\u{E7A8}", 0xDEA584}
  # Go (nf-seti-go)
  def icon_and_color(:go), do: {"\u{E626}", 0x00ADD8}
  # JavaScript (nf-seti-javascript)
  def icon_and_color(:javascript), do: {"\u{E781}", 0xF7DF1E}
  # JSX (nf-seti-react)
  def icon_and_color(:javascript_react), do: {"\u{E7BA}", 0x61DAFB}
  # TypeScript (nf-seti-typescript)
  def icon_and_color(:typescript), do: {"\u{E628}", 0x3178C6}
  # TSX (nf-seti-react)
  def icon_and_color(:typescript_react), do: {"\u{E7BA}", 0x3178C6}
  # Python (nf-dev-python)
  def icon_and_color(:python), do: {"\u{E73C}", 0x3776AB}
  # Ruby (nf-dev-ruby)
  def icon_and_color(:ruby), do: {"\u{E739}", 0xCC342D}
  # C (nf-custom-c)
  def icon_and_color(:c), do: {"\u{E61E}", 0x599EFF}
  # C++ (nf-custom-cpp)
  def icon_and_color(:cpp), do: {"\u{E61D}", 0xF34B7D}
  # C# (nf-md-language_csharp)
  def icon_and_color(:c_sharp), do: {"\u{F031B}", 0x68217A}
  # Java (nf-dev-java)
  def icon_and_color(:java), do: {"\u{E738}", 0xCC3E44}
  # Kotlin (nf-seti-kotlin)
  def icon_and_color(:kotlin), do: {"\u{E634}", 0x7F52FF}
  # Scala (nf-dev-scala)
  def icon_and_color(:scala), do: {"\u{E737}", 0xCC3E44}
  # Swift (nf-dev-swift)
  def icon_and_color(:swift), do: {"\u{E755}", 0xF05138}
  # Dart (nf-dev-dart)
  def icon_and_color(:dart), do: {"\u{E798}", 0x03589C}
  # Lua (nf-seti-lua)
  def icon_and_color(:lua), do: {"\u{E620}", 0x000080}
  # PHP (nf-dev-php)
  def icon_and_color(:php), do: {"\u{E73D}", 0x777BB3}
  # Perl (nf-dev-perl)
  def icon_and_color(:perl), do: {"\u{E769}", 0x39457E}
  # R (nf-seti-r)
  def icon_and_color(:r), do: {"\u{E68A}", 0x276DC3}
  # Haskell (nf-dev-haskell)
  def icon_and_color(:haskell), do: {"\u{E777}", 0x5E5086}
  # OCaml (nf-seti-ocaml)
  def icon_and_color(:ocaml), do: {"\u{E67F}", 0xEC6813}
  # Gleam (star/sparkle)
  def icon_and_color(:gleam), do: {"\u{F0E7}", 0xFFAFEF}
  # Nix (nf-md-nix)
  def icon_and_color(:nix), do: {"\u{F0313}", 0x7EBAE4}
  # Emacs Lisp (nf-custom-emacs)
  def icon_and_color(:emacs_lisp), do: {"\u{E632}", 0x7F5AB6}
  # Vim (nf-dev-vim)
  def icon_and_color(:vim), do: {"\u{E62B}", 0x019833}
  # Fish (nf-dev-terminal)
  def icon_and_color(:fish), do: {"\u{E795}", 0x89E051}
  # Bash/Shell (nf-dev-terminal)
  def icon_and_color(:bash), do: {"\u{E795}", 0x89E051}

  # ── Web / markup ───────────────────────────────────────────────────────────

  # HTML (nf-seti-html)
  def icon_and_color(:html), do: {"\u{E736}", 0xE34C26}
  # CSS (nf-dev-css3)
  def icon_and_color(:css), do: {"\u{E749}", 0x563D7C}
  # SCSS (nf-dev-sass)
  def icon_and_color(:scss), do: {"\u{E74B}", 0xCD6799}
  # GraphQL (nf-md-graphql)
  def icon_and_color(:graphql), do: {"\u{F0877}", 0xE10098}

  # ── Data / config ──────────────────────────────────────────────────────────

  # JSON (nf-seti-json)
  def icon_and_color(:json), do: {"\u{E60B}", 0xCBCB41}
  # YAML (nf-seti-yml)
  def icon_and_color(:yaml), do: {"\u{E6A8}", 0xCB171E}
  # TOML (nf-seti-config)
  def icon_and_color(:toml), do: {"\u{E615}", 0x9C4221}
  # XML (nf-md-xml)
  def icon_and_color(:xml), do: {"\u{F05C0}", 0xE37933}
  # CSV (nf-fa-table)
  def icon_and_color(:csv), do: {"\u{F0CE}", 0x89E051}
  # SQL (nf-dev-database)
  def icon_and_color(:sql), do: {"\u{E706}", 0xDAD8D8}
  # Protobuf (nf-md-code_braces)
  def icon_and_color(:protobuf), do: {"\u{F0614}", 0x6A9FB5}
  # INI/Config (nf-seti-config)
  def icon_and_color(:ini), do: {"\u{E615}", 0x6D8086}
  def icon_and_color(:conf), do: {"\u{E615}", 0x6D8086}
  def icon_and_color(:editorconfig), do: {"\u{E615}", 0x6D8086}
  # HCL/Terraform (nf-md-terraform)
  def icon_and_color(:hcl), do: {"\u{F1062}", 0x7B42BC}

  # ── Markdown / docs ────────────────────────────────────────────────────────

  # Markdown (nf-dev-markdown)
  def icon_and_color(:markdown), do: {"\u{E73E}", 0x519ABA}
  # Text (nf-seti-text)
  def icon_and_color(:text), do: {"\u{E612}", 0x89E051}

  # ── DevOps ─────────────────────────────────────────────────────────────────

  # Docker (nf-md-docker)
  def icon_and_color(:dockerfile), do: {"\u{F0868}", 0x0DB7ED}
  # Makefile (nf-seti-makefile)
  def icon_and_color(:make), do: {"\u{E673}", 0x6D8086}
  # Diff (nf-md-compare)
  def icon_and_color(:diff), do: {"\u{F1492}", 0x41535B}
  # Git (nf-dev-git)
  def icon_and_color(:gitconfig), do: {"\u{E702}", 0xF14C28}

  # ── Special buffer types ───────────────────────────────────────────────────

  # Agent (nf-md-robot)
  def icon_and_color(:agent), do: {"\u{F06A9}", 0x7EC8E3}
  # Messages (nf-md-message_text)
  def icon_and_color(:messages), do: {"\u{F0369}", 0x519ABA}
  # Scratch (nf-md-note_edit)
  def icon_and_color(:scratch), do: {"\u{F03EB}", 0xCBCB41}
  # Help (nf-md-help_circle)
  def icon_and_color(:help), do: {"\u{F02D7}", 0x00ADD8}

  # ── Fallback ───────────────────────────────────────────────────────────────

  # Generic file (nf-seti-default)
  def icon_and_color(_), do: {"\u{E612}", 0x6D8086}
end
