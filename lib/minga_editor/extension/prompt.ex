defmodule MingaEditor.Extension.Prompt do
  @moduledoc """
  Opens source-owned prompts in the editor minibuffer from an extension callback.

  Return the editor state from a successful opening to display the prompt.
  The host dismisses the prompt before calling `MingaEditor.Extension.Prompt.Handler`
  with the original `args`. Replacing a prompt or unloading its owner discards it
  without calling its handler.
  """

  alias Minga.Extension.InvocationContext
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.PromptUI
  alias MingaEditor.State.Prompt, as: PromptState

  @type admission :: :replace | :if_idle
  @type decision :: :accepted | :canceled
  @type option :: {:label, String.t()} | {:admission, admission()}
  @type text_option :: option() | {:default, String.t()}
  @type error ::
          :modal_busy
          | :not_extension_callback
          | :source_unavailable
          | :invalid_handler
          | :unsupported_shell
  @type result :: {:ok, EditorAPI.state()} | {:error, error()}

  @doc """
  Opens a text prompt. `:label` is required; `:default` is initially empty.

  Admission defaults to `:replace`. Use `admission: :if_idle` to preserve an active
  modal and receive `{:error, :modal_busy}` instead. Quit and conflict prompts
  are never replaced.
  """
  @spec text(EditorAPI.state(), module(), term(), [text_option()]) :: result()
  def text(state, handler, args, opts) when is_atom(handler) do
    opts = Keyword.validate!(opts, [:label, default: "", admission: :replace])

    unless is_binary(Keyword.fetch!(opts, :default)) do
      raise ArgumentError, ":default must be a string"
    end

    open(state, :text, handler, args, opts)
  end

  @doc """
  Opens a Yes/No prompt with the required `:label` and the same admission policy as `text/4`.

  `y` or Yes accepts; `n`, Escape, or No cancels. No other key or paste chooses an answer.
  """
  @spec confirm(EditorAPI.state(), module(), term(), [option()]) :: result()
  def confirm(state, handler, args, opts) when is_atom(handler) do
    opts = Keyword.validate!(opts, [:label, admission: :replace])
    open(state, :confirm, handler, args, opts)
  end

  @spec open(EditorAPI.state(), PromptState.kind(), module(), term(), keyword()) :: result()
  defp open(state, kind, handler, args, opts) do
    unless is_binary(Keyword.fetch!(opts, :label)) do
      raise ArgumentError, ":label must be a string"
    end

    unless Keyword.fetch!(opts, :admission) in [:replace, :if_idle] do
      raise ArgumentError, ":admission must be :replace or :if_idle"
    end

    case InvocationContext.current_source() do
      {:ok, {:extension, _name} = source} ->
        PromptUI.open_extension(state, source, kind, handler, args, opts)

      _other ->
        {:error, :not_extension_callback}
    end
  end
end
