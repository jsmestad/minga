defmodule Minga.Editor.SignatureHelp do
  @moduledoc """
  State and rendering for LSP signature help tooltips.

  When the user types `(` or `,` inside a function call, a floating
  window appears above the cursor showing the function signature with
  the active parameter highlighted. Supports multiple overloaded
  signatures with cycling via C-j/C-k.

  ## Lifecycle

  1. User types `(` or `,` in insert mode
  2. `CompletionHandling.maybe_handle/4` detects the trigger character
  3. `textDocument/signatureHelp` request sent to LSP
  4. Response parsed into `SignatureHelp` state
  5. Rendered as an overlay in the Chrome stage
  6. Dismissed on `)`, Escape, or cursor movement outside the call
  """

  alias MingaAgent.Markdown
  alias Minga.Core.Face
  alias Minga.Editor.DisplayList
  alias Minga.Editor.FloatingWindow
  alias Minga.Editor.MarkdownStyles

  @enforce_keys [:signatures, :active_signature, :active_parameter, :anchor_row, :anchor_col]
  defstruct signatures: [],
            active_signature: 0,
            active_parameter: 0,
            anchor_row: 0,
            anchor_col: 0

  @typedoc "A parsed signature."
  @type signature :: %{
          label: String.t(),
          documentation: String.t(),
          parameters: [parameter()]
        }

  @typedoc "A parsed parameter."
  @type parameter :: %{
          label: String.t(),
          documentation: String.t()
        }

  @typedoc "Signature help state."
  @type t :: %__MODULE__{
          signatures: [signature()],
          active_signature: non_neg_integer(),
          active_parameter: non_neg_integer(),
          anchor_row: non_neg_integer(),
          anchor_col: non_neg_integer()
        }

  # ── Construction ─────────────────────────────────────────────────────────

  @doc """
  Creates a new signature help state from an LSP SignatureHelp response.
  """
  @spec from_response(map(), non_neg_integer(), non_neg_integer()) :: t() | nil
  def from_response(response, cursor_row, cursor_col) do
    sigs = parse_signatures(Map.get(response, "signatures", []))

    case sigs do
      [] ->
        nil

      _ ->
        %__MODULE__{
          signatures: sigs,
          active_signature: Map.get(response, "activeSignature", 0),
          active_parameter: Map.get(response, "activeParameter", 0),
          anchor_row: cursor_row,
          anchor_col: cursor_col
        }
    end
  end

  # ── Navigation ──────────────────────────────────────────────────────────

  @doc "Cycle to the next signature overload."
  @spec next_signature(t()) :: t()
  def next_signature(%__MODULE__{signatures: sigs, active_signature: idx} = sh) do
    %{sh | active_signature: rem(idx + 1, length(sigs))}
  end

  @doc "Cycle to the previous signature overload."
  @spec prev_signature(t()) :: t()
  def prev_signature(%__MODULE__{signatures: sigs, active_signature: idx} = sh) do
    total = length(sigs)
    %{sh | active_signature: rem(idx - 1 + total, total)}
  end

  # ── Rendering ───────────────────────────────────────────────────────────

  @doc """
  Renders the signature help as display list draws for an overlay.

  Shows the active signature label with the active parameter highlighted.
  If there are multiple signatures, shows a "1/3" counter.
  """
  @spec render(t(), {pos_integer(), pos_integer()}, map()) :: [DisplayList.draw()]
  def render(%__MODULE__{signatures: []}, _viewport, _theme), do: []

  def render(%__MODULE__{} = sh, viewport, theme) do
    sig = Enum.at(sh.signatures, sh.active_signature)
    if sig == nil, do: [], else: do_render(sh, sig, viewport, theme)
  end

  # ── Private: parsing ────────────────────────────────────────────────────

  @spec parse_signatures([map()]) :: [signature()]
  defp parse_signatures(sigs) when is_list(sigs) do
    Enum.map(sigs, &parse_signature/1)
  end

  @spec parse_signature(map()) :: signature()
  defp parse_signature(raw) do
    %{
      label: Map.get(raw, "label", ""),
      documentation: extract_doc(Map.get(raw, "documentation")),
      parameters: parse_parameters(Map.get(raw, "parameters", []))
    }
  end

  @spec parse_parameters([map()]) :: [parameter()]
  defp parse_parameters(params) when is_list(params) do
    Enum.map(params, &parse_parameter/1)
  end

  @spec parse_parameter(map()) :: parameter()
  defp parse_parameter(raw) do
    label =
      case Map.get(raw, "label") do
        l when is_binary(l) -> l
        [start, stop] when is_integer(start) and is_integer(stop) -> "#{start}:#{stop}"
        _ -> ""
      end

    %{
      label: label,
      documentation: extract_doc(Map.get(raw, "documentation"))
    }
  end

  @spec extract_doc(term()) :: String.t()
  defp extract_doc(nil), do: ""
  defp extract_doc(text) when is_binary(text), do: String.trim(text)
  defp extract_doc(%{"value" => value}) when is_binary(value), do: String.trim(value)
  defp extract_doc(_), do: ""

  # ── Private: rendering ─────────────────────────────────────────────────

  @spec do_render(t(), signature(), {pos_integer(), pos_integer()}, map()) ::
          [DisplayList.draw()]
  defp do_render(sh, sig, viewport, theme) do
    popup_theme = Map.get(theme, :popup, %{bg: 0x21242B, border_fg: 0x5B6268, title_fg: 0xBBC2CF})
    syntax = Map.get(theme, :syntax, %{})
    editor_theme = Map.get(theme, :editor, %{})
    base_fg = Map.get(editor_theme, :fg, 0xBBC2CF)
    highlight_fg = Map.get(syntax, :keyword, 0x51AFEF)

    # Build content: signature label with active parameter highlighted
    content_draws = build_signature_draws(sig, sh.active_parameter, base_fg, highlight_fg)

    # Add parameter documentation if available
    param_doc_draws =
      case Enum.at(sig.parameters, sh.active_parameter) do
        %{documentation: doc} when doc != "" ->
          render_param_doc(doc, syntax, base_fg)

        _ ->
          []
      end

    all_draws = content_draws ++ param_doc_draws

    content_height =
      if param_doc_draws == [],
        do: 1,
        else:
          2 +
            length(
              Markdown.parse(
                Enum.at(sig.parameters, sh.active_parameter, %{documentation: ""}).documentation
              )
            )

    # Counter for multiple signatures
    counter =
      if length(sh.signatures) > 1 do
        "#{sh.active_signature + 1}/#{length(sh.signatures)}"
      else
        nil
      end

    # Compute width from signature label
    sig_width = String.length(sig.label) + 4
    width = max(sig_width, 30) |> min(elem(viewport, 1) - 4)

    spec = %FloatingWindow.Spec{
      content: all_draws,
      width: {:cols, width + 2},
      height: {:rows, min(content_height, 8) + 2},
      position: {:anchor, sh.anchor_row, sh.anchor_col, :above},
      border: :rounded,
      footer: counter,
      theme: popup_theme,
      viewport: viewport
    }

    FloatingWindow.render(spec)
  end

  @spec render_param_doc(String.t(), map(), non_neg_integer()) :: [DisplayList.draw()]
  defp render_param_doc(doc, syntax, base_fg) do
    parsed = Markdown.parse(doc)

    Enum.with_index(parsed, 1)
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
          signature(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [DisplayList.draw()]
  defp build_signature_draws(sig, active_param, base_fg, highlight_fg) do
    label = sig.label
    params = sig.parameters

    case find_active_param_range(label, params, active_param) do
      {start_col, end_col} ->
        # Split label into three parts: before, active parameter, after
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

  @spec find_active_param_range(String.t(), [parameter()], non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp find_active_param_range(_label, [], _active), do: nil
  defp find_active_param_range(_label, _params, active) when active < 0, do: nil

  defp find_active_param_range(label, params, active) do
    param = Enum.at(params, active)

    if param do
      case :binary.match(label, param.label) do
        {start, len} -> {start, start + len}
        :nomatch -> nil
      end
    else
      nil
    end
  end
end
