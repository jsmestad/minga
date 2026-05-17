defmodule MingaEditor.Renderer.Gutter.SignContext do
  @moduledoc """
  Per-window data needed to render gutter signs.

  Sign rendering uses the same diagnostic, git, theme, and decoration data for every line in a window render pass. This struct keeps that data together so `Gutter.render_sign/4` receives one focused context instead of a long positional argument list.
  """

  alias Minga.Core.Decorations
  alias Minga.Diagnostics.Diagnostic
  alias MingaEditor.Renderer.Context

  @enforce_keys [:colors, :git_colors]
  defstruct diagnostic_signs: %{},
            git_signs: %{},
            colors: nil,
            git_colors: nil,
            decorations: %Decorations{}

  @typedoc "Per-window gutter sign rendering context."
  @type t :: %__MODULE__{
          diagnostic_signs: %{non_neg_integer() => Diagnostic.severity()},
          git_signs: %{non_neg_integer() => atom()},
          colors: MingaEditor.UI.Theme.Gutter.t(),
          git_colors: MingaEditor.UI.Theme.Git.t(),
          decorations: Decorations.t()
        }

  @doc "Builds a sign context from a renderer context."
  @spec from_render_context(Context.t()) :: t()
  def from_render_context(%Context{
        diagnostic_signs: diagnostic_signs,
        git_signs: git_signs,
        gutter_colors: colors,
        git_colors: git_colors,
        decorations: decorations
      }) do
    %__MODULE__{
      diagnostic_signs: diagnostic_signs,
      git_signs: git_signs,
      colors: colors,
      git_colors: git_colors,
      decorations: decorations
    }
  end
end
