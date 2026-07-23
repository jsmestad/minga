defmodule MingaEditor.Agent.UIState.TranscriptProjection do
  @moduledoc false

  alias MingaEditor.Agent.Transcript
  alias MingaEditor.UI.Theme

  @type t :: %__MODULE__{
          line_index: [{non_neg_integer(), Transcript.line_type()}],
          messages: [term()],
          message_pairs: [{pos_integer(), term()}],
          styled: styled_cache(),
          styled_fingerprint: non_neg_integer() | nil,
          display_start: non_neg_integer(),
          provenance_jump: MingaEditor.Agent.ProvenanceJump.t() | nil,
          version: non_neg_integer()
        }

  @type rendered_message :: %{
          styled_lines: MingaEditor.Agent.MarkdownHighlight.styled_lines() | nil,
          markdown_blocks: [Minga.RenderModel.UI.AgentChat.MarkdownBlock.t()] | nil
        }

  @type styled_cache :: [rendered_message() | nil] | nil

  defstruct line_index: [],
            messages: [],
            message_pairs: [],
            styled: nil,
            styled_fingerprint: nil,
            display_start: 0,
            provenance_jump: nil,
            version: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec cache_display(t(), Transcript.display_result(), styled_cache(), keyword()) :: t()
  def cache_display(%__MODULE__{} = projection, display, styled, opts \\ []) do
    %{
      projection
      | line_index: display.line_index,
        messages: display.display_messages,
        message_pairs: display.display_message_pairs,
        styled: styled,
        styled_fingerprint: Keyword.get(opts, :styled_fingerprint),
        display_start: Keyword.get(opts, :display_start, projection.display_start),
        provenance_jump: Keyword.get(opts, :provenance_jump, projection.provenance_jump)
    }
  end

  @spec clear(t()) :: t()
  def clear(%__MODULE__{version: version}) do
    %__MODULE__{version: version}
  end

  @spec cache_styled(t(), styled_cache(), non_neg_integer() | nil) :: t()
  def cache_styled(%__MODULE__{} = projection, styled, styled_fingerprint) do
    %{projection | styled: styled, styled_fingerprint: styled_fingerprint}
  end

  @spec bump_version(t()) :: t()
  def bump_version(%__MODULE__{version: version} = projection),
    do: %{projection | version: version + 1}

  @spec set_display_start(t(), non_neg_integer()) :: t()
  def set_display_start(%__MODULE__{} = projection, display_start)
      when is_integer(display_start) and display_start >= 0 do
    %{projection | display_start: display_start}
  end

  @spec set_provenance_jump(t(), MingaEditor.Agent.ProvenanceJump.t() | nil) :: t()
  def set_provenance_jump(%__MODULE__{} = projection, jump),
    do: %{projection | provenance_jump: jump}

  @spec clear_provenance_jump(t()) :: t()
  def clear_provenance_jump(%__MODULE__{} = projection), do: %{projection | provenance_jump: nil}

  @spec styled_for(t(), non_neg_integer()) :: {:ok, styled_cache()} | :stale
  def styled_for(%__MODULE__{styled_fingerprint: fingerprint, styled: styled}, fingerprint),
    do: {:ok, styled}

  def styled_for(%__MODULE__{}, _fingerprint), do: :stale

  @spec styled_cache_fingerprint(Theme.t() | map() | nil) :: non_neg_integer()
  def styled_cache_fingerprint(nil), do: 0
  def styled_cache_fingerprint(%Theme{syntax: syntax}), do: styled_cache_fingerprint(syntax)

  def styled_cache_fingerprint(theme_syntax) when is_map(theme_syntax),
    do: :erlang.phash2(theme_syntax)
end
