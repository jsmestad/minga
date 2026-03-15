defmodule Minga.Editor.Renderer.Context do
  @moduledoc """
  Rendering context for a single render pass.

  Bundles the per-frame invariants that every line renderer needs:
  viewport geometry, visual selection bounds, search match positions,
  gutter width, and the active substitute-confirm match (if any).

  Built once per render call and threaded through the line rendering
  pipeline, keeping individual function signatures focused on the
  per-line values that actually vary (line text, screen row, buffer line).
  """

  alias Minga.Buffer.Decorations
  alias Minga.Diagnostics.Diagnostic
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.Viewport
  alias Minga.Highlight

  @enforce_keys [:viewport, :gutter_w, :content_w]
  defstruct viewport: nil,
            visual_selection: nil,
            search_matches: [],
            gutter_w: 0,
            content_w: 0,
            confirm_match: nil,
            highlight: nil,
            cursorline_bg: nil,
            nav_flash: nil,
            nav_flash_bg: nil,
            editor_bg: 0x282C34,
            has_sign_column: false,
            diagnostic_signs: %{},
            git_signs: %{},
            search_colors: %Minga.Theme.Search{
              highlight_fg: 0x000000,
              highlight_bg: 0xECBE7B,
              current_bg: 0xFF6C6B
            },
            git_colors: %Minga.Theme.Git{
              added_fg: 0x98BE65,
              modified_fg: 0x51AFEF,
              deleted_fg: 0xFF6C6B
            },
            decorations: %Decorations{},
            gutter_colors: %Minga.Theme.Gutter{
              fg: 0x555555,
              current_fg: 0xBBC2CF,
              error_fg: 0xFF6C6B,
              warning_fg: 0xECBE7B,
              info_fg: 0x51AFEF,
              hint_fg: 0x555555
            }

  @typedoc """
  Represents the bounds of a visual selection for rendering.

  * `nil` — no active selection
  * `{:char, start_pos, end_pos}` — characterwise selection
  * `{:line, start_line, end_line}` — linewise selection
  """
  @type visual_selection ::
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          viewport: Viewport.t(),
          visual_selection: visual_selection(),
          search_matches: [SearchHighlight.search_match()],
          gutter_w: non_neg_integer(),
          content_w: pos_integer(),
          confirm_match: SearchHighlight.search_match() | nil,
          highlight: Highlight.t() | nil,
          cursorline_bg: Minga.Theme.color() | nil,
          nav_flash: Minga.Editor.NavFlash.t() | nil,
          nav_flash_bg: Minga.Theme.color() | nil,
          editor_bg: Minga.Theme.color(),
          has_sign_column: boolean(),
          diagnostic_signs: %{non_neg_integer() => Diagnostic.severity()},
          git_signs: %{non_neg_integer() => Minga.Git.Diff.hunk_type()},
          decorations: Decorations.t(),
          git_colors: Minga.Theme.Git.t(),
          search_colors: Minga.Theme.Search.t(),
          gutter_colors: Minga.Theme.Gutter.t()
        }
end
