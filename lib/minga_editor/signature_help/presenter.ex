defmodule MingaEditor.SignatureHelp.Presenter do
  @moduledoc "Builds signature-help geometry and display-list presentation from its immutable value."

  alias Minga.Core.Face
  alias MingaAgent.Markdown
  alias MingaEditor.DisplayList
  alias MingaEditor.FloatingWindow
  alias MingaEditor.MarkdownStyles
  alias MingaEditor.SignatureHelp

  @doc "Returns the tooltip's conservative outer rect in screen cells."
  @spec box(SignatureHelp.t(), {pos_integer(), pos_integer()}, map()) ::
          MingaEditor.Layout.rect() | nil
  def box(%SignatureHelp{} = signature_help, viewport, theme) do
    case spec(signature_help, viewport, theme) do
      nil -> nil
      window_spec -> FloatingWindow.box(window_spec)
    end
  end

  @spec spec(SignatureHelp.t(), {pos_integer(), pos_integer()}, map()) ::
          FloatingWindow.Spec.t() | nil
  defp spec(%SignatureHelp{signatures: []}, _viewport, _theme), do: nil

  defp spec(%SignatureHelp{} = signature_help, viewport, theme) do
    case Enum.at(signature_help.signatures, signature_help.active_signature) do
      nil -> nil
      signature -> build_spec(signature_help, signature, viewport, theme)
    end
  end

  @spec build_spec(
          SignatureHelp.t(),
          SignatureHelp.signature(),
          {pos_integer(), pos_integer()},
          map()
        ) :: FloatingWindow.Spec.t()
  defp build_spec(signature_help, signature, viewport, theme) do
    popup_theme =
      Map.get(theme, :popup, %{bg: 0x21242B, border_fg: 0x5B6268, title_fg: 0xBBC2CF})

    syntax = Map.get(theme, :syntax, %{})
    editor_theme = Map.get(theme, :editor, %{})
    base_fg = Map.get(editor_theme, :fg, 0xBBC2CF)
    highlight_fg = Map.get(syntax, :keyword, 0x51AFEF)

    content_draws =
      build_signature_draws(
        signature,
        signature_help.active_parameter,
        base_fg,
        highlight_fg
      )

    param_doc_draws =
      case Enum.at(signature.parameters, signature_help.active_parameter) do
        %{documentation: documentation} when documentation != "" ->
          render_param_doc(documentation, syntax, base_fg)

        _other ->
          []
      end

    all_draws = content_draws ++ param_doc_draws
    content_height = content_height(signature, signature_help.active_parameter, param_doc_draws)
    counter = overload_counter(signature_help)
    width = max(String.length(signature.label) + 4, 30) |> min(elem(viewport, 1) - 4)

    %FloatingWindow.Spec{
      content: all_draws,
      width: {:cols, width + 2},
      height: {:rows, min(content_height, 8) + 2},
      position: {:anchor, signature_help.anchor_row, signature_help.anchor_col, :above},
      border: :rounded,
      footer: counter,
      theme: popup_theme,
      viewport: viewport
    }
  end

  @spec content_height(SignatureHelp.signature(), non_neg_integer(), [DisplayList.draw()]) ::
          pos_integer()
  defp content_height(_signature, _active_parameter, []), do: 1

  defp content_height(signature, active_parameter, _param_doc_draws) do
    documentation =
      signature.parameters
      |> Enum.at(active_parameter, %{documentation: ""})
      |> Map.fetch!(:documentation)

    2 + Enum.count(Markdown.parse(documentation))
  end

  @spec overload_counter(SignatureHelp.t()) :: String.t() | nil
  defp overload_counter(%SignatureHelp{signatures: [_single]}), do: nil

  defp overload_counter(%SignatureHelp{signatures: signatures, active_signature: index}) do
    "#{index + 1}/#{Enum.count(signatures)}"
  end

  @spec render_param_doc(String.t(), map(), non_neg_integer()) :: [DisplayList.draw()]
  defp render_param_doc(documentation, syntax, base_fg) do
    documentation
    |> Markdown.parse()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{segments, _type}, row} ->
      {draws, _col} =
        Enum.reduce(segments, {[], 0}, fn {text, style}, {acc, col} ->
          draw =
            DisplayList.draw(row, col, text, MarkdownStyles.to_draw_opts(style, syntax, base_fg))

          {[draw | acc], col + String.length(text)}
        end)

      Enum.reverse(draws)
    end)
  end

  @spec build_signature_draws(
          SignatureHelp.signature(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp build_signature_draws(signature, active_parameter, base_fg, highlight_fg) do
    label = signature.label

    case find_active_param_range(label, signature.parameters, active_parameter) do
      {start_col, end_col} ->
        before = String.slice(label, 0, start_col)
        active = String.slice(label, start_col, end_col - start_col)
        after_text = String.slice(label, end_col, String.length(label) - end_col)

        [
          DisplayList.draw(0, 0, before, Face.new(fg: base_fg)),
          DisplayList.draw(
            0,
            String.length(before),
            active,
            Face.new(fg: highlight_fg, bold: true)
          ),
          DisplayList.draw(
            0,
            String.length(before) + String.length(active),
            after_text,
            Face.new(fg: base_fg)
          )
        ]

      nil ->
        [DisplayList.draw(0, 0, label, Face.new(fg: base_fg))]
    end
  end

  @spec find_active_param_range(
          String.t(),
          [SignatureHelp.parameter()],
          non_neg_integer()
        ) :: {non_neg_integer(), non_neg_integer()} | nil
  defp find_active_param_range(_label, [], _active), do: nil

  defp find_active_param_range(label, parameters, active) do
    case Enum.at(parameters, active) do
      nil ->
        nil

      parameter ->
        case :binary.match(label, parameter.label) do
          {start, length} -> {start, start + length}
          :nomatch -> nil
        end
    end
  end
end
