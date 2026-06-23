defmodule MingaEditor.Agent.UIState.Panel do
  @moduledoc """
  Prompt editing and chat display state.

  Holds the data for the agent prompt (buffer, history, cursor, paste blocks)
  and chat display (scroll, spinner, model config, display offset). This is
  the "panel" half of the agent UI, separated from layout/search/preview
  concerns in `UIState.View`.

  Most callers interact through `UIState` functions rather than accessing
  this struct directly. `AgentAccess.panel/1` returns this struct for
  read-only field access in input handlers and renderers.
  """

  alias MingaAgent.Config, as: AgentConfig
  alias Minga.Buffer
  alias Minga.Editing.Scroll

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
          display_start_index: non_neg_integer(),
          mention_completion: MingaAgent.FileMention.completion() | nil,
          pasted_blocks: [paste_block()],
          cached_line_index: [{non_neg_integer(), MingaEditor.Agent.Transcript.line_type()}],
          cached_display_messages: [term()],
          cached_display_message_pairs: [{pos_integer(), term()}],
          cached_styled_messages: [MingaEditor.Agent.MarkdownHighlight.styled_lines()] | nil,
          message_version: non_neg_integer(),
          credentials_configured: boolean(),
          provenance_jump: MingaEditor.Agent.ProvenanceJump.t() | nil
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
            display_start_index: 0,
            mention_completion: nil,
            pasted_blocks: [],
            cached_line_index: [],
            cached_display_messages: [],
            cached_display_message_pairs: [],
            cached_styled_messages: nil,
            message_version: 0,
            credentials_configured: false,
            provenance_jump: nil

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

  # ── Buffer readers ──────────────────────────────────────────────────────

  @doc "Returns the input lines as a list of strings."
  @spec input_lines(t()) :: [String.t()]
  def input_lines(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.content(pid) |> String.split("\n")
  end

  def input_lines(%__MODULE__{}), do: [""]

  @doc "Returns the input cursor position as `{line, col}`."
  @spec input_cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def input_cursor(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.cursor(pid)
  end

  def input_cursor(%__MODULE__{}), do: {0, 0}

  @doc "Returns the number of input lines."
  @spec input_line_count(t()) :: pos_integer()
  def input_line_count(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.line_count(pid)
  end

  def input_line_count(%__MODULE__{}), do: 1

  @doc "Returns true if the input is empty (single empty line)."
  @spec input_empty?(t()) :: boolean()
  def input_empty?(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.content(pid) == ""
  end

  def input_empty?(%__MODULE__{}), do: true

  @doc "Returns the raw input text (with placeholders, not substituted)."
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.content(pid)
  end

  def input_text(%__MODULE__{}), do: ""

  @doc "Increments the message version counter. Used to invalidate the GUI fingerprint cache when message content changes (collapse toggles, new messages, etc.)."
  @spec bump_message_version(t()) :: t()
  def bump_message_version(%__MODULE__{message_version: v} = panel) do
    %{panel | message_version: v + 1}
  end

  @doc "Arms a pending provenance jump (Enter from a code-provenance popup)."
  @spec set_provenance_jump(t(), MingaEditor.Agent.ProvenanceJump.t() | nil) :: t()
  def set_provenance_jump(%__MODULE__{} = panel, jump) do
    %{panel | provenance_jump: jump}
  end

  @doc "Clears any pending provenance jump (e.g. when the user sends a new prompt)."
  @spec clear_provenance_jump(t()) :: t()
  def clear_provenance_jump(%__MODULE__{} = panel), do: %{panel | provenance_jump: nil}
end
