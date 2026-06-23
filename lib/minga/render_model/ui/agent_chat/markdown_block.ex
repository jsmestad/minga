defmodule Minga.RenderModel.UI.AgentChat.MarkdownBlock do
  @moduledoc """
  Semantic markdown block for agent chat messages.

  The BEAM owns markdown structure. Frontends render these blocks directly and must not infer code cards from styled-run flags or decorative text.
  """

  import Bitwise

  @typedoc "Markdown block kind encoded on the gui_agent_chat wire."
  @type kind :: :paragraph | :heading | :list_item | :blockquote | :rule | :spacer | :code_block

  @typedoc "A styled text run: {text, fg_rgb, bg_rgb, flags} or with a trailing url."
  @type styled_run ::
          {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()}

  @typedoc "A line of styled runs."
  @type styled_line :: [styled_run()]

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          kind: kind(),
          flags: non_neg_integer(),
          lines: [styled_line()],
          level: non_neg_integer(),
          indent: non_neg_integer(),
          ordered: boolean(),
          ordinal: non_neg_integer(),
          height: non_neg_integer(),
          language: String.t(),
          label: String.t(),
          target_path: String.t(),
          capability_flags: non_neg_integer()
        }

  @enforce_keys [:id, :kind]
  defstruct id: 0,
            kind: :paragraph,
            flags: 0,
            lines: [],
            level: 0,
            indent: 0,
            ordered: false,
            ordinal: 0,
            height: 1,
            language: "",
            label: "",
            target_path: "",
            capability_flags: 0

  @complete_flag 0x01
  @copy_capability 0x01

  @spec paragraph(non_neg_integer(), [styled_line()]) :: t()
  def paragraph(id, lines), do: %__MODULE__{id: id, kind: :paragraph, lines: lines}

  @spec heading(non_neg_integer(), non_neg_integer(), [styled_line()]) :: t()
  def heading(id, level, lines),
    do: %__MODULE__{id: id, kind: :heading, level: level, lines: lines}

  @spec list_item(non_neg_integer(), non_neg_integer(), boolean(), non_neg_integer(), [
          styled_line()
        ]) :: t()
  def list_item(id, indent, ordered?, ordinal, lines) do
    %__MODULE__{
      id: id,
      kind: :list_item,
      indent: indent,
      ordered: ordered?,
      ordinal: ordinal,
      lines: lines
    }
  end

  @spec blockquote(non_neg_integer(), [styled_line()]) :: t()
  def blockquote(id, lines), do: %__MODULE__{id: id, kind: :blockquote, lines: lines}

  @spec rule(non_neg_integer()) :: t()
  def rule(id), do: %__MODULE__{id: id, kind: :rule}

  @spec spacer(non_neg_integer(), non_neg_integer()) :: t()
  def spacer(id, height), do: %__MODULE__{id: id, kind: :spacer, height: height}

  @spec code_block(non_neg_integer(), String.t(), String.t(), String.t() | nil, boolean(), [
          styled_line()
        ]) :: t()
  def code_block(id, language, label, target_path, complete?, lines) do
    %__MODULE__{
      id: id,
      kind: :code_block,
      flags: if(complete?, do: @complete_flag, else: 0),
      lines: lines,
      language: language || "",
      label: label || "Code",
      target_path: target_path || "",
      capability_flags: @copy_capability
    }
  end

  @spec map_lines(t(), (styled_line() -> styled_line())) :: t()
  def map_lines(%__MODULE__{lines: lines} = block, mapper) when is_function(mapper, 1) do
    %{block | lines: Enum.map(lines, mapper)}
  end

  @spec map_lines(t(), (styled_line() -> styled_line()), pos_integer()) :: t()
  def map_lines(%__MODULE__{lines: lines} = block, mapper, max_lines)
      when is_function(mapper, 1) and is_integer(max_lines) and max_lines > 0 do
    %{block | lines: lines |> Enum.take(max_lines) |> Enum.map(mapper)}
  end

  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{flags: flags}), do: (flags &&& @complete_flag) != 0
end
