defmodule MingaEditor.Renderer.Context do
  @moduledoc """
  Rendering context for a single render pass.

  Bundles the per-frame invariants that every line renderer needs:
  viewport geometry, visual selection bounds, search match positions,
  gutter width, and the active substitute-confirm match (if any).

  Built once per render call and threaded through the line rendering
  pipeline, keeping individual function signatures focused on the
  per-line values that actually vary (line text, screen row, buffer line).
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Core.WidthOracle
  alias Minga.Core.WidthOracle.Monospace
  alias Minga.Diagnostics.Diagnostic
  alias Minga.Editing.Search.Match
  alias MingaEditor.Viewport
  alias MingaEditor.UI.Highlight

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
            is_gui: false,
            has_sign_column: true,
            diagnostic_signs: %{},
            git_signs: %{},
            git_colors: %MingaEditor.UI.Theme.Git{
              added_fg: 0x98BE65,
              modified_fg: 0x51AFEF,
              deleted_fg: 0xFF6C6B
            },
            decorations: %Decorations{},
            gutter_colors: %MingaEditor.UI.Theme.Gutter{
              fg: 0x555555,
              current_fg: 0xBBC2CF,
              error_fg: 0xFF6C6B,
              warning_fg: 0xECBE7B,
              info_fg: 0x51AFEF,
              hint_fg: 0x555555,
              fold_fg: 0x555555
            },
            show_invisible: false,
            tab_width: 2,
            whitespace_face: nil,
            indent_guide_face: nil,
            indent_guide_active_face: nil,
            hl_todo_faces: %{},
            cursor_col: 0,
            cursor_line: nil,
            search_colors: nil,
            document_highlight_colors: nil,
            wrap_on: false,
            line_number_style: :absolute,
            width_oracle: %Monospace{},
            hover_row: nil,
            fold_ranges: []

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
          search_matches: [Match.t()],
          gutter_w: non_neg_integer(),
          content_w: pos_integer(),
          confirm_match: Match.t() | nil,
          highlight: Highlight.t() | nil,
          cursorline_bg: MingaEditor.UI.Theme.color() | nil,
          nav_flash: MingaEditor.NavFlash.t() | nil,
          nav_flash_bg: MingaEditor.UI.Theme.color() | nil,
          editor_bg: MingaEditor.UI.Theme.color(),
          is_gui: boolean(),
          has_sign_column: boolean(),
          diagnostic_signs: %{non_neg_integer() => Diagnostic.severity()},
          git_signs: %{non_neg_integer() => Minga.Core.Diff.hunk_type()},
          decorations: Decorations.t(),
          git_colors: MingaEditor.UI.Theme.Git.t(),
          gutter_colors: MingaEditor.UI.Theme.Gutter.t(),
          show_invisible: boolean(),
          tab_width: pos_integer(),
          whitespace_face: Face.t() | nil,
          indent_guide_face: Face.t() | nil,
          indent_guide_active_face: Face.t() | nil,
          hl_todo_faces: %{atom() => Face.t()},
          cursor_col: non_neg_integer(),
          cursor_line: non_neg_integer() | nil,
          search_colors: MingaEditor.UI.Theme.Search.t() | nil,
          document_highlight_colors: term(),
          wrap_on: boolean(),
          line_number_style: atom(),
          width_oracle: WidthOracle.t(),
          hover_row: non_neg_integer() | nil,
          fold_ranges: [term()]
        }

  @doc "Returns the context with a different decoration set."
  @spec with_decorations(t(), Decorations.t()) :: t()
  def with_decorations(%__MODULE__{} = ctx, %Decorations{} = decorations) do
    %{ctx | decorations: decorations}
  end
end
