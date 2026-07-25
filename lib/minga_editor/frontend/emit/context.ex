defmodule MingaEditor.Frontend.Emit.Context do
  @moduledoc """
  Strict emit-local projection over a materialized render input.

  The accepted intent stays nested and identical. This context keeps only renderer-local values plus derived emit fields.
  """

  alias Minga.Editing.Completion
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.WorkspaceIntent
  alias MingaEditor.Shell.Traditional.GitToast
  alias MingaEditor.State
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  @type t :: %__MODULE__{
          intent: Intent.t(),
          workspace: WorkspaceIntent.t(),
          windows: Windows.t(MingaEditor.Renderer.RenderWindow.t()),
          layout: Layout.t(),
          font_registry: FontRegistry.t(),
          message_store: MessageStore.t(),
          title: String.t(),
          completion: Completion.t() | nil,
          tab_bar: TabBar.t() | nil,
          git_toast: GitToast.t() | nil,
          frame_seq: non_neg_integer() | nil,
          surface_placements: [MingaEditor.Layout.SurfaceRegistry.wire_placement()],
          gui?: boolean(),
          acknowledgement_required?: boolean(),
          link_cursor: boolean()
        }

  @enforce_keys [:intent, :workspace, :windows, :layout, :font_registry, :message_store, :title]
  defstruct [
    :intent,
    :workspace,
    :windows,
    :layout,
    :font_registry,
    :message_store,
    :title,
    :completion,
    :tab_bar,
    :git_toast,
    :frame_seq,
    surface_placements: [],
    gui?: false,
    acknowledgement_required?: false,
    link_cursor: false
  ]

  @doc "Builds an emit context from materialized render input."
  @spec from_input(Input.t()) :: t()
  def from_input(%Input{} = input) do
    frame = input.intent.frame
    shell_state = frame.shell_state
    gui? = MingaEditor.Frontend.gui?(frame.capabilities)

    %__MODULE__{
      intent: input.intent,
      workspace: input.workspace,
      windows: input.windows,
      layout: MingaEditor.Layout.get(input),
      font_registry: input.font_registry,
      message_store: input.message_store,
      title: compute_title(input, frame.shell, shell_state),
      completion: MingaEditor.Shell.Traditional.ModalWorkflow.completion(input),
      tab_bar: tab_bar(shell_state),
      git_toast: git_toast(shell_state),
      frame_seq: input.frame_seq,
      acknowledgement_required?: frame.backend != :headless and not is_nil(frame.port_manager),
      surface_placements: MingaEditor.Layout.SurfaceRegistry.wire_placements(input),
      gui?: gui?,
      link_cursor: gui? and input.workspace.cmd_hover_link != nil
    }
  end

  @doc "Strict test/helper path from editor state through intent and renderer-local input."
  @spec from_editor_state(State.t() | Input.t()) :: t()
  def from_editor_state(%State{} = state), do: state |> Input.from_editor_state() |> from_input()
  def from_editor_state(%Input{} = input), do: from_input(input)

  @spec compute_title(Input.t(), module(), term()) :: String.t()
  defp compute_title(input, shell, shell_state) do
    case shell.gui_payload(input) do
      nil ->
        compute_standard_title(input, shell_state)

      other ->
        Minga.Log.warning(
          :render,
          "Unsupported GUI shell payload #{inspect(other)}; using standard title"
        )

        compute_standard_title(input, shell_state)
    end
  end

  @spec compute_standard_title(Input.t(), term()) :: String.t()
  defp compute_standard_title(%Input{} = input, shell_state) do
    if MingaEditor.Frontend.gui?(input.intent.frame.capabilities) do
      MingaEditor.Title.format_gui(input)
    else
      format = Minga.Config.get(:title_format) |> to_string()
      title = MingaEditor.Title.format(input, format)
      tb = tab_bar(shell_state)

      if tb && TabBar.any_attention?(tb), do: "[!] " <> title, else: title
    end
  end

  @doc "Accepts message-store write-back produced while building UI models."
  @spec accept_message_store(t(), MessageStore.t()) :: t()
  def accept_message_store(%__MODULE__{} = ctx, %MessageStore{} = message_store),
    do: %{ctx | message_store: message_store}

  @spec tab_bar(term()) :: TabBar.t() | nil
  defp tab_bar(%TraditionalState{} = shell_state), do: TraditionalState.tab_bar(shell_state)
  defp tab_bar(_shell_state), do: nil

  @spec git_toast(term()) :: GitToast.t() | nil
  defp git_toast(%TraditionalState{git_toast: git_toast}), do: git_toast
  defp git_toast(_shell_state), do: nil
end
