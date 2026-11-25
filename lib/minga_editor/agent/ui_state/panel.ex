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
  alias MingaAgent.ModelSelection
  alias MingaAgent.Credentials
  alias Minga.Editing.Scroll
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Agent.PromptViewport

  @typedoc "A collapsed paste block. Stores the original text and whether the block is currently expanded for editing."
  @type paste_block :: %{text: String.t(), expanded: boolean()}

  @typedoc "Prompt editing and chat display state."
  @type t :: %__MODULE__{
          visible: boolean(),
          scroll: Scroll.t(),
          prompt_buffer: pid() | nil,
          prompt_viewport: PromptViewport.t(),
          prompt_history: [String.t()],
          history_index: integer(),
          spinner_frame: non_neg_integer(),
          provider_name: String.t(),
          provider_label: String.t() | nil,
          model_name: String.t(),
          model_problem: String.t() | nil,
          thinking_level: String.t() | nil,
          input_focused: boolean(),
          transcript: TranscriptProjection.t(),
          mention_completion: MingaAgent.FileMention.completion() | nil,
          pasted_blocks: [paste_block()],
          credentials_configured: boolean(),
          credential_readiness: Credentials.readiness()
        }

  defstruct visible: false,
            scroll: %Scroll{},
            prompt_buffer: nil,
            prompt_viewport: %PromptViewport{},
            prompt_history: [],
            history_index: -1,
            spinner_frame: 0,
            provider_name: "",
            provider_label: nil,
            model_name: "unknown",
            model_problem: nil,
            thinking_level: nil,
            input_focused: false,
            transcript: TranscriptProjection.new(),
            mention_completion: nil,
            pasted_blocks: [],
            credentials_configured: false,
            credential_readiness: :unconfigured

  @doc "Records physical fit without changing the prompt draft or its reading anchor."
  @spec fit_prompt(t(), pos_integer(), pos_integer()) :: t()
  def fit_prompt(%__MODULE__{prompt_viewport: viewport} = panel, columns, rows),
    do: %{panel | prompt_viewport: PromptViewport.fit(viewport, columns, rows)}

  @spec scroll_prompt(t(), PromptViewport.marker(), PromptViewport.anchor()) :: t()
  def scroll_prompt(%__MODULE__{prompt_viewport: viewport} = panel, marker, anchor),
    do: %{panel | prompt_viewport: PromptViewport.read_at(viewport, marker, anchor)}

  @spec follow_prompt_cursor(t()) :: t()
  def follow_prompt_cursor(%__MODULE__{prompt_viewport: viewport} = panel),
    do: %{panel | prompt_viewport: PromptViewport.follow(viewport)}

  @doc "Creates a new panel state with truthful model defaults."
  @spec new() :: t()
  def new do
    model = AgentConfig.configured_model() || AgentConfig.unconfigured_model()

    %__MODULE__{
      provider_name: AgentConfig.extract_provider_prefix(model),
      model_name: model,
      credentials_configured: false,
      credential_readiness: :checking
    }
  end

  @doc """
  Refreshes a stale unqualified model name from the user's configured model.

  The panel never discovers a model itself. With no configured model it stays unresolved until the session reports its selection.
  """
  @spec ensure_configured_model(t()) :: t()
  def ensure_configured_model(%__MODULE__{} = panel),
    do: refresh_configured_model(panel, AgentConfig.configured_model())

  @doc "Refreshes a stale unqualified model name from a specific options server's configured model."
  @spec ensure_configured_model(t(), Minga.Config.Options.server()) :: t()
  def ensure_configured_model(%__MODULE__{} = panel, options_server),
    do: refresh_configured_model(panel, AgentConfig.configured_model(options_server))

  @spec refresh_configured_model(t(), String.t() | nil) :: t()
  defp refresh_configured_model(panel, nil), do: panel

  defp refresh_configured_model(panel, configured) do
    if resolved_model?(panel.model_name), do: panel, else: refresh_model(panel, configured)
  end

  @spec resolved_model?(String.t()) :: boolean()
  defp resolved_model?(model) do
    AgentConfig.extract_provider_prefix(model) != "" or String.starts_with?(model, "ms2_")
  end

  @spec refresh_model(t(), String.t()) :: t()
  defp refresh_model(panel, default_model) do
    if stale_unqualified_model?(panel.model_name, default_model) do
      %{
        panel
        | provider_name: AgentConfig.extract_provider_prefix(default_model),
          provider_label: nil,
          model_name: default_model
      }
    else
      panel
    end
  end

  @doc "Sets whether any provider credential is configured (drives the model indicator)."
  @spec set_credentials_configured(t(), boolean()) :: t()
  def set_credentials_configured(%__MODULE__{} = panel, configured?) do
    readiness = if configured?, do: :configured, else: :unconfigured
    %{panel | credentials_configured: configured?, credential_readiness: readiness}
  end

  @doc "Sets explicit credential readiness while retaining the compatibility boolean."
  @spec set_credential_readiness(t(), Credentials.readiness()) :: t()
  def set_credential_readiness(%__MODULE__{} = panel, readiness)
      when readiness in [:checking, :configured, :unconfigured] do
    %{
      panel
      | credentials_configured: readiness == :configured,
        credential_readiness: readiness
    }
  end

  @doc """
  Projects model status without treating deferred resolution as missing credentials.

  An unresolved model reads "Resolving model…" until the session reports its selection, or the session's explanation when it could not resolve one.
  """
  @spec model_label(t()) :: String.t()
  def model_label(%__MODULE__{model_name: model}) when model not in ["", "unknown"], do: model
  def model_label(%__MODULE__{credential_readiness: :unconfigured}), do: "No model configured"
  def model_label(%__MODULE__{model_problem: problem}) when is_binary(problem), do: problem
  def model_label(%__MODULE__{}), do: "Resolving model…"

  @doc "Whether the panel names a model, from configuration or from the session's selection."
  @spec configured_model?(t()) :: boolean()
  def configured_model?(%__MODULE__{model_name: model}), do: model not in ["", "unknown"]

  @doc "Records the session's explanation for an unresolved model, or clears it."
  @spec project_model_problem(t(), String.t() | nil) :: t()
  def project_model_problem(%__MODULE__{} = panel, problem)
      when is_binary(problem) or is_nil(problem),
      do: %{panel | model_problem: problem}

  @doc """
  Projects the agent chat model identity as `provider:model` when the selected route names its provider, otherwise as `model_label/1`.

  Frontends split this value at its first `:`, so a provider label that contains `:` is omitted rather than split in the wrong place. Status text shown in place of a model, such as a resolver error that quotes a `provider:model` spec, gets an empty provider (`:text`) when it contains `:`, so no part of it reads as a provider. A configured model spec such as `openai:gpt` keeps its own split.
  """
  @spec chat_model_label(t()) :: String.t()
  def chat_model_label(%__MODULE__{provider_label: label} = panel) when is_binary(label) do
    if String.contains?(label, ":"),
      do: model_label(panel),
      else: label <> ":" <> model_label(panel)
  end

  def chat_model_label(%__MODULE__{} = panel) do
    label = model_label(panel)

    if configured_model?(panel) or not String.contains?(label, ":"),
      do: label,
      else: ":" <> label
  end

  @doc "Projects authoritative model display facts without discovering models or changing readiness."
  @spec project_model_selection(t(), ModelSelection.t() | nil) :: t()
  def project_model_selection(%__MODULE__{} = panel, nil),
    do: %{
      panel
      | model_name: "unknown",
        provider_name: "",
        provider_label: nil,
        thinking_level: nil
    }

  def project_model_selection(%__MODULE__{} = panel, %ModelSelection{} = selection) do
    %{
      panel
      | model_name: selection.route.display_name,
        provider_name: selection.route.model_provider,
        provider_label: selection.route.provider_label,
        thinking_level: selection.policy.reasoning.effort
    }
  end

  @doc """
  Makes the next session started from this panel run on `selection`'s exact route, for a task started beside a conversation.

  The model name is the selection's stable route id, so the session resolves the same route rather than a display name.
  """
  @spec start_on_model(t(), ModelSelection.t()) :: t()
  def start_on_model(%__MODULE__{} = panel, %ModelSelection{} = selection) do
    %{
      panel
      | model_name: ModelSelection.id(selection),
        provider_name: selection.route.model_provider,
        provider_label: nil,
        thinking_level: selection.policy.reasoning.effort
    }
  end

  @doc "Sets the displayed provider name."
  @spec set_provider_name(t(), String.t()) :: t()
  def set_provider_name(%__MODULE__{} = panel, provider) when is_binary(provider) do
    %{panel | provider_name: provider}
  end

  @doc "Sets the active model name."
  @spec set_model_name(t(), String.t()) :: t()
  def set_model_name(%__MODULE__{} = panel, model) when is_binary(model) do
    %{panel | model_name: model, provider_label: nil}
  end

  @doc "Returns a renderer-boundary copy without the retained transcript display."
  @spec render_snapshot(t()) :: t()
  def render_snapshot(%__MODULE__{transcript: projection} = panel) do
    case TranscriptProjection.render_snapshot(projection) do
      ^projection -> panel
      snapshot -> %{panel | transcript: snapshot}
    end
  end

  @doc "Installs the new source and its remapped reading position together."
  @spec install_transcript(t(), TranscriptProjection.t(), :keep | :follow | non_neg_integer()) ::
          t()
  def install_transcript(%__MODULE__{} = panel, projection, reading) do
    scroll =
      case reading do
        :keep -> panel.scroll
        :follow -> Scroll.pin_to_bottom(panel.scroll)
        offset -> Scroll.set_offset(panel.scroll, offset)
      end

    %{panel | transcript: projection, scroll: scroll}
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

  @doc "Records a transcript content revision (streamed text, collapse toggles, new messages). It does not change the presentation epoch."
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
