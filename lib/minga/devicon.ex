defmodule Minga.Devicon do
  @moduledoc """
  Maps filetypes and special buffer types to Nerd Font icons and colors.

  Used by the tab bar, file tree, buffer picker, and anywhere else that
  displays a filename alongside a visual indicator. Pure functional module
  with pattern-matched clauses; no GenServer, no ETS.

  Colors follow community conventions (nvim-web-devicons palette).
  """

  @typedoc "A 24-bit RGB color value."
  @type color :: 0x000000..0xFFFFFF

  # ── Icon constants (Nerd Font codepoints) ─────────────────────────────────
  # Using module attributes so they're defined once and reusable.

  # Special buffer types
  @icon_agent "\u{F06A9}"
  @icon_messages "\u{F449}"
  @icon_scratch "\u{F0399}"
  @icon_help "\u{F059}"

  # Languages
  @icon_elixir "\u{E62D}"
  @icon_erlang "\u{E7B1}"
  @icon_heex "\u{E62D}"
  @icon_gleam "\u{E62D}"
  @icon_zig "\u{E6A9}"
  @icon_rust "\u{E7A8}"
  @icon_go "\u{E626}"
  @icon_c "\u{E61E}"
  @icon_cpp "\u{E61D}"
  @icon_c_sharp "\u{F031B}"
  @icon_java "\u{E738}"
  @icon_kotlin "\u{E634}"
  @icon_scala "\u{E737}"
  @icon_python "\u{E73C}"
  @icon_ruby "\u{E739}"
  @icon_javascript "\u{E74E}"
  @icon_react "\u{E7BA}"
  @icon_typescript "\u{E628}"
  @icon_lua "\u{E620}"
  @icon_bash "\u{E795}"
  @icon_fish "\u{E795}"
  @icon_php "\u{E73D}"
  @icon_perl "\u{E769}"
  @icon_r "\u{F25D}"
  @icon_haskell "\u{E777}"
  @icon_ocaml "\u{E67A}"
  @icon_swift "\u{E755}"
  @icon_dart "\u{E798}"
  @icon_nix "\u{F313}"
  @icon_emacs "\u{E632}"
  @icon_vim "\u{E62B}"

  # Markup & data
  @icon_html "\u{E736}"
  @icon_css "\u{E749}"
  @icon_scss "\u{E749}"
  @icon_markdown "\u{E73E}"
  @icon_json "\u{E60B}"
  @icon_yaml "\u{E6A8}"
  @icon_toml "\u{E6B2}"
  @icon_xml "\u{F05C0}"
  @icon_graphql "\u{E662}"
  @icon_sql "\u{E706}"
  @icon_csv "\u{F0219}"
  @icon_protobuf "\u{E6A8}"
  @icon_hcl "\u{E6A8}"

  # Config & infra
  @icon_dockerfile "\u{E7B0}"
  @icon_make "\u{E779}"
  @icon_git "\u{E702}"
  @icon_config "\u{E615}"
  @icon_diff "\u{E728}"
  @icon_text "\u{F0219}"
  @icon_fallback "\u{F15B}"

  @doc "Returns the Nerd Font icon for a filetype or special buffer type."
  @spec icon(atom()) :: String.t()

  # ── Special buffer types ──────────────────────────────────────────────────
  def icon(:agent), do: @icon_agent
  def icon(:messages), do: @icon_messages
  def icon(:scratch), do: @icon_scratch
  def icon(:help), do: @icon_help

  # ── Languages ─────────────────────────────────────────────────────────────
  def icon(:elixir), do: @icon_elixir
  def icon(:erlang), do: @icon_erlang
  def icon(:heex), do: @icon_heex
  def icon(:lfe), do: @icon_erlang
  def icon(:gleam), do: @icon_gleam
  def icon(:zig), do: @icon_zig
  def icon(:rust), do: @icon_rust
  def icon(:go), do: @icon_go
  def icon(:c), do: @icon_c
  def icon(:cpp), do: @icon_cpp
  def icon(:c_sharp), do: @icon_c_sharp
  def icon(:java), do: @icon_java
  def icon(:kotlin), do: @icon_kotlin
  def icon(:scala), do: @icon_scala
  def icon(:python), do: @icon_python
  def icon(:ruby), do: @icon_ruby
  def icon(:javascript), do: @icon_javascript
  def icon(:javascript_react), do: @icon_react
  def icon(:typescript), do: @icon_typescript
  def icon(:typescript_react), do: @icon_react
  def icon(:lua), do: @icon_lua
  def icon(:bash), do: @icon_bash
  def icon(:fish), do: @icon_fish
  def icon(:php), do: @icon_php
  def icon(:perl), do: @icon_perl
  def icon(:r), do: @icon_r
  def icon(:haskell), do: @icon_haskell
  def icon(:ocaml), do: @icon_ocaml
  def icon(:swift), do: @icon_swift
  def icon(:dart), do: @icon_dart
  def icon(:nix), do: @icon_nix
  def icon(:emacs_lisp), do: @icon_emacs
  def icon(:vim), do: @icon_vim

  # ── Markup & data ─────────────────────────────────────────────────────────
  def icon(:html), do: @icon_html
  def icon(:css), do: @icon_css
  def icon(:scss), do: @icon_scss
  def icon(:markdown), do: @icon_markdown
  def icon(:json), do: @icon_json
  def icon(:yaml), do: @icon_yaml
  def icon(:toml), do: @icon_toml
  def icon(:xml), do: @icon_xml
  def icon(:graphql), do: @icon_graphql
  def icon(:sql), do: @icon_sql
  def icon(:csv), do: @icon_csv
  def icon(:protobuf), do: @icon_protobuf
  def icon(:hcl), do: @icon_hcl

  # ── Config & infra ───────────────────────────────────────────────────────
  def icon(:dockerfile), do: @icon_dockerfile
  def icon(:make), do: @icon_make
  def icon(:gitconfig), do: @icon_git
  def icon(:editorconfig), do: @icon_config
  def icon(:conf), do: @icon_config
  def icon(:ini), do: @icon_config
  def icon(:diff), do: @icon_diff
  def icon(:text), do: @icon_text

  # ── Fallback ──────────────────────────────────────────────────────────────
  def icon(_), do: @icon_fallback

  @doc "Returns the 24-bit RGB color for a filetype or special buffer type."
  @spec color(atom()) :: color()

  # ── Special buffer types ──────────────────────────────────────────────────
  def color(:agent), do: 0x98BE65
  def color(:messages), do: 0x51AFEF
  def color(:scratch), do: 0xECBE7B
  def color(:help), do: 0x46D9FF

  # ── Languages ─────────────────────────────────────────────────────────────
  def color(:elixir), do: 0x9B59B6
  def color(:erlang), do: 0xA90533
  def color(:heex), do: 0x9B59B6
  def color(:lfe), do: 0xA90533
  def color(:gleam), do: 0xFFAFEE
  def color(:zig), do: 0xF69A1B
  def color(:rust), do: 0xDEA584
  def color(:go), do: 0x00ADD8
  def color(:c), do: 0x599EFF
  def color(:cpp), do: 0xF34B7D
  def color(:c_sharp), do: 0x68217A
  def color(:java), do: 0xCC3E44
  def color(:kotlin), do: 0x7F52FF
  def color(:scala), do: 0xCC3E44
  def color(:python), do: 0x3776AB
  def color(:ruby), do: 0xCC342D
  def color(:javascript), do: 0xF7DF1E
  def color(:javascript_react), do: 0x61DAFB
  def color(:typescript), do: 0x3178C6
  def color(:typescript_react), do: 0x61DAFB
  def color(:lua), do: 0x000080
  def color(:bash), do: 0x89E051
  def color(:fish), do: 0x89E051
  def color(:php), do: 0x777BB3
  def color(:perl), do: 0x39457E
  def color(:r), do: 0x276DC3
  def color(:haskell), do: 0x5E5086
  def color(:ocaml), do: 0xF18803
  def color(:swift), do: 0xF05138
  def color(:dart), do: 0x00B4AB
  def color(:nix), do: 0x7EBAE4
  def color(:emacs_lisp), do: 0x7F5AB6
  def color(:vim), do: 0x019833

  # ── Markup & data ─────────────────────────────────────────────────────────
  def color(:html), do: 0xE34C26
  def color(:css), do: 0x563D7C
  def color(:scss), do: 0xCD6799
  def color(:markdown), do: 0x519ABA
  def color(:json), do: 0xCBCB41
  def color(:yaml), do: 0xCB171E
  def color(:toml), do: 0x9C4221
  def color(:xml), do: 0xE37933
  def color(:graphql), do: 0xE10098
  def color(:sql), do: 0xDAD8D8
  def color(:csv), do: 0x89E051
  def color(:protobuf), do: 0x5B9BD5
  def color(:hcl), do: 0x844FBA

  # ── Config & infra ───────────────────────────────────────────────────────
  def color(:dockerfile), do: 0x2496ED
  def color(:make), do: 0x6D8086
  def color(:gitconfig), do: 0xF14E32
  def color(:editorconfig), do: 0x6D8086
  def color(:conf), do: 0x6D8086
  def color(:ini), do: 0x6D8086
  def color(:diff), do: 0x41535B
  def color(:text), do: 0x89E051

  # ── Fallback ──────────────────────────────────────────────────────────────
  def color(_), do: 0x6D8086

  @doc "Returns `{icon, color}` for a filetype or special buffer type."
  @spec icon_and_color(atom()) :: {String.t(), color()}
  def icon_and_color(filetype) do
    {icon(filetype), color(filetype)}
  end
end
