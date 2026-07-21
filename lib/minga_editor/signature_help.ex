defmodule MingaEditor.SignatureHelp do
  @moduledoc """
  Immutable lifecycle value for LSP signature help.

  The value owns response parsing, replacement, dismissal, and overload selection. `MingaEditor.SignatureHelp.Presenter` owns geometry.
  """

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

  @typedoc "Signature-help lifecycle value."
  @type t :: %__MODULE__{
          signatures: [signature()],
          active_signature: non_neg_integer(),
          active_parameter: non_neg_integer(),
          anchor_row: non_neg_integer(),
          anchor_col: non_neg_integer()
        }

  @doc "Creates signature-help state from an LSP SignatureHelp response."
  @spec from_response(map(), non_neg_integer(), non_neg_integer()) :: t() | nil
  def from_response(response, cursor_row, cursor_col) do
    signatures = parse_signatures(Map.get(response, "signatures", []))

    case signatures do
      [] ->
        nil

      _ ->
        %__MODULE__{
          signatures: signatures,
          active_signature: Map.get(response, "activeSignature", 0),
          active_parameter: Map.get(response, "activeParameter", 0),
          anchor_row: cursor_row,
          anchor_col: cursor_col
        }
    end
  end

  @doc "Replaces any prior signature-help value with a fresh response value."
  @spec replace(t() | nil, t()) :: t()
  def replace(nil, %__MODULE__{} = signature_help), do: signature_help

  def replace(%__MODULE__{}, %__MODULE__{} = signature_help),
    do: signature_help

  @doc "Dismisses signature help."
  @spec dismiss(t() | nil) :: nil
  def dismiss(nil), do: nil
  def dismiss(%__MODULE__{}), do: nil

  @doc "Cycles to the next signature overload."
  @spec next_signature(t()) :: t()
  def next_signature(%__MODULE__{signatures: signatures, active_signature: index} = help) do
    %{help | active_signature: rem(index + 1, Enum.count(signatures))}
  end

  @doc "Cycles to the previous signature overload."
  @spec prev_signature(t()) :: t()
  def prev_signature(%__MODULE__{signatures: signatures, active_signature: index} = help) do
    total = Enum.count(signatures)
    %{help | active_signature: rem(index - 1 + total, total)}
  end

  @spec parse_signatures([map()]) :: [signature()]
  defp parse_signatures(signatures) when is_list(signatures) do
    Enum.map(signatures, &parse_signature/1)
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
  defp parse_parameters(parameters) when is_list(parameters) do
    Enum.map(parameters, &parse_parameter/1)
  end

  @spec parse_parameter(map()) :: parameter()
  defp parse_parameter(raw) do
    label =
      case Map.get(raw, "label") do
        label when is_binary(label) -> label
        [start, stop] when is_integer(start) and is_integer(stop) -> "#{start}:#{stop}"
        _other -> ""
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
  defp extract_doc(_other), do: ""
end
