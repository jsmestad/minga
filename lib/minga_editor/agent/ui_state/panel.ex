defmodule MingaEditor.Agent.UIState.Panel do
  @moduledoc """
  Prompt editing and chat display state.

  Holds the data for the agent prompt (buffer, history, cursor, paste blocks)
  and chat display (scroll, spinner, model config, display offset). This is
  the "panel" half of the agent UI, separated from layout/search/preview
  concerns in `UIState.View`.

  Most callers interact through `UIState` functions rather than accessing
  this struct directly.
  """

  alias MingaAgent.Config, as: AgentConfig
  alias MingaEditor.Agent.Transcript
  alias Minga.Editing.Scroll
  alias MingaEditor.Agent.UIState.TranscriptProjection

  @typedoc "A collapsed paste block. Stores the original text and whether the block is currently expanded for editing."
  @type paste_block :: %{text: String.t(), expanded: boolean()}

  @typedoc "Prompt editing and chat display state."
  @type t :: %__MODULE__{
          visible: boolean(),
          scroll: Scroll.t(),
          prompt_buffer: pid() | nil,
          prompt_history: [String.t()],
          history_index: integer(),
          spinner_frame: non_neg_integer(),
          provider_name: String.t(),
          model_name: String.t(),
          thinking_level: String.t(),
          input_focused: boolean(),
          transcript: TranscriptProjection.t(),
          mention_completion: MingaAgent.FileMention.completion() | nil,
          pasted_blocks: [paste_block()],
          credentials_configured: boolean()
        }

  defstruct visible: false,
            scroll: %Scroll{},
            prompt_buffer: nil,
            prompt_history: [],
            history_index: -1,
            spinner_frame: 0,
            provider_name: "",
            model_name: "unknown",
            thinking_level: "medium",
            input_focused: false,
            transcript: TranscriptProjection.new(),
            mention_completion: nil,
            pasted_blocks: [],
            credentials_configured: false

  @doc "Creates a new panel state with truthful model defaults."
  @spec new() :: t()
  def new do
    model = AgentConfig.default_model()

    %__MODULE__{
      provider_name: AgentConfig.extract_provider_prefix(model),
      model_name: model,
      credentials_configured: false
    }
  end

  @doc "Refreshes stale unqualified model names to the current credential-aware default."
  @spec ensure_configured_model(t()) :: t()
  def ensure_configured_model(%__MODULE__{} = panel) do
    default_model = AgentConfig.default_model()

    if stale_unqualified_model?(panel.model_name, default_model) do
      %{
        panel
        | provider_name: AgentConfig.extract_provider_prefix(default_model),
          model_name: default_model
      }
    else
      panel
    end
  end

  @doc "Refreshes stale unqualified model names from a specific options server."
  @spec ensure_configured_model(t(), Minga.Config.Options.server()) :: t()
  def ensure_configured_model(%__MODULE__{} = panel, options_server) do
    default_model = AgentConfig.default_model(options_server)

    if stale_unqualified_model?(panel.model_name, default_model) do
      %{
        panel
        | provider_name: AgentConfig.extract_provider_prefix(default_model),
          model_name: default_model
      }
    else
      panel
    end
  end

  @doc "Sets whether any provider credential is configured (drives the model indicator)."
  @spec set_credentials_configured(t(), boolean()) :: t()
  def set_credentials_configured(%__MODULE__{} = panel, configured?) do
    panel = ensure_configured_model(panel)
    %{panel | credentials_configured: configured?}
  end

  @doc "Sets the displayed provider name."
  @spec set_provider_name(t(), String.t()) :: t()
  def set_provider_name(%__MODULE__{} = panel, provider) when is_binary(provider) do
    %{panel | provider_name: provider}
  end

  @doc "Sets the active model name."
  @spec set_model_name(t(), String.t()) :: t()
  def set_model_name(%__MODULE__{} = panel, model) when is_binary(model) do
    %{panel | model_name: model}
  end

  @spec cache_transcript_display(
          t(),
          Transcript.display_result(),
          TranscriptProjection.styled_cache(),
          keyword()
        ) ::
          t()
  def cache_transcript_display(
        %__MODULE__{transcript: projection} = panel,
        display,
        styled_messages,
        opts \\ []
      ) do
    %{
      panel
      | transcript: TranscriptProjection.cache_display(projection, display, styled_messages, opts)
    }
  end

  @spec clear_transcript_cache(t()) :: t()
  def clear_transcript_cache(%__MODULE__{transcript: projection} = panel) do
    %{panel | transcript: TranscriptProjection.clear(projection)}
  end

  @doc "Stores semantic scroll state for the agent transcript panel."
  @spec set_scroll(t(), Scroll.t()) :: t()
  def set_scroll(%__MODULE__{} = panel, %Scroll{} = scroll), do: %{panel | scroll: scroll}

  @spec set_display_start(t(), non_neg_integer()) :: t()
  def set_display_start(%__MODULE__{transcript: projection} = panel, display_start) do
    %{panel | transcript: TranscriptProjection.set_display_start(projection, display_start)}
  end

  @doc "Replaces cached styled transcript runs without changing the display window."
  @spec cache_styled_messages(t(), TranscriptProjection.styled_cache(), non_neg_integer() | nil) ::
          t()
  def cache_styled_messages(
        %__MODULE__{transcript: projection} = panel,
        styled_messages,
        styled_fingerprint
      ) do
    %{
      panel
      | transcript:
          TranscriptProjection.cache_styled(projection, styled_messages, styled_fingerprint)
    }
  end

  @spec stale_unqualified_model?(String.t(), String.t()) :: boolean()
  defp stale_unqualified_model?(model, default_model)
       when model in ["", "unknown"] and default_model not in ["", "unknown"] do
    true
  end

  defp stale_unqualified_model?(model, default_model) do
    AgentConfig.extract_provider_prefix(model) == "" and
      AgentConfig.extract_provider_prefix(default_model) != "" and
      model != default_model
  end

  @doc "Clears the active file mention completion."
  @spec clear_mention_completion(t()) :: t()
  def clear_mention_completion(%__MODULE__{} = panel) do
    %{panel | mention_completion: nil}
  end

  @doc "Increments the message version counter. Used to invalidate the GUI fingerprint cache when message content changes (collapse toggles, new messages, etc.)."
  @spec bump_message_version(t()) :: t()
  def bump_message_version(%__MODULE__{transcript: projection} = panel) do
    %{panel | transcript: TranscriptProjection.bump_version(projection)}
  end

  @doc "Arms a pending provenance jump (Enter from a code-provenance popup)."
  @spec set_provenance_jump(t(), MingaEditor.Agent.ProvenanceJump.t() | nil) :: t()
  def set_provenance_jump(%__MODULE__{transcript: projection} = panel, jump) do
    %{panel | transcript: TranscriptProjection.set_provenance_jump(projection, jump)}
  end

  @doc "Clears any pending provenance jump (e.g. when the user sends a new prompt)."
  @spec clear_provenance_jump(t()) :: t()
  def clear_provenance_jump(%__MODULE__{transcript: projection} = panel) do
    %{panel | transcript: TranscriptProjection.clear_provenance_jump(projection)}
  end
end
