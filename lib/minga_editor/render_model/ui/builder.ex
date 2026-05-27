defmodule MingaEditor.RenderModel.UI.Builder do
  @moduledoc false

  alias Minga.Buffer
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.AgentChatBuilder
  alias MingaEditor.RenderModel.UI.AgentContextBuilder
  alias MingaEditor.RenderModel.UI.BoardBuilder
  alias MingaEditor.RenderModel.UI.BreadcrumbBuilder
  alias MingaEditor.RenderModel.UI.CompletionBuilder
  alias MingaEditor.RenderModel.UI.FileTreeBuilder
  alias MingaEditor.RenderModel.UI.GitStatusBuilder
  alias MingaEditor.RenderModel.UI.MinibufferBuilder
  alias MingaEditor.RenderModel.UI.NotificationsBuilder
  alias MingaEditor.RenderModel.UI.ObservatoryBuilder
  alias MingaEditor.RenderModel.UI.PickerBuilder
  alias MingaEditor.RenderModel.UI.SearchStateBuilder
  alias MingaEditor.RenderModel.UI.SidebarsBuilder
  alias MingaEditor.RenderModel.UI.SignatureHelpBuilder
  alias MingaEditor.RenderModel.UI.StatusBarBuilder
  alias MingaEditor.RenderModel.UI.TabBarBuilder
  alias MingaEditor.RenderModel.UI.ThemeBuilder
  alias MingaEditor.RenderModel.UI.WhichKeyBuilder
  alias MingaEditor.RenderModel.UI.WorkspacesBuilder
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias Minga.RenderModel

  @spec build_ui(Context.t(), StatusBarData.t() | nil, term()) :: RenderModel.UI.t()
  def build_ui(%Context{} = ctx, status_bar_data \\ nil, minibuffer_data \\ nil) do
    file_path = active_buffer_path(ctx)
    root = file_tree_root(ctx)
    active_buf = active_buffer_pid(ctx)
    gui_payload = shell_gui_payload(ctx)
    sb_data = status_bar_data || ctx.status_bar_data

    %RenderModel.UI{
      theme: ThemeBuilder.build(ctx.theme),
      breadcrumb: BreadcrumbBuilder.build(file_path, root),
      which_key: build_which_key(ctx),
      notifications: NotificationsBuilder.build(ctx.notifications),
      search_state: SearchStateBuilder.build(ctx.search, active_buf),
      git_status: build_git_status(ctx),
      agent_context: AgentContextBuilder.build(gui_payload),
      status_bar: build_status_bar(sb_data, ctx),
      observatory: ObservatoryBuilder.build(ctx.shell_state),
      board: BoardBuilder.build(gui_payload),
      tab_bar: TabBarBuilder.build(ctx),
      workspaces: WorkspacesBuilder.build(ctx),
      sidebars: SidebarsBuilder.build(ctx),
      file_tree: FileTreeBuilder.build(ctx),
      picker: PickerBuilder.build(ctx),
      minibuffer: MinibufferBuilder.build(minibuffer_data),
      completion: CompletionBuilder.build(ctx),
      signature_help: SignatureHelpBuilder.build(ctx),
      agent_chat: AgentChatBuilder.build(ctx)
    }
  end

  @spec build_git_status(Context.t()) :: Minga.RenderModel.UI.GitStatus.t()
  defp build_git_status(%{
         shell_state: %{git_status_panel: %{} = data},
         git_syncing: syncing,
         git_toast: toast
       }) do
    GitStatusBuilder.build(data, syncing, toast)
  end

  defp build_git_status(%{git_syncing: syncing, git_toast: toast}) do
    GitStatusBuilder.build(nil, syncing, toast)
  end

  @spec build_which_key(Context.t()) :: Minga.RenderModel.UI.WhichKey.t() | nil
  defp build_which_key(%{shell_state: %{whichkey: wk}}) when not is_nil(wk) do
    WhichKeyBuilder.build(wk)
  end

  defp build_which_key(_ctx), do: nil

  @spec active_buffer_pid(Context.t()) :: pid() | nil
  defp active_buffer_pid(%{buffers: %{active: buf}}) when is_pid(buf), do: buf
  defp active_buffer_pid(_ctx), do: nil

  @spec active_buffer_path(Context.t()) :: String.t() | nil
  defp active_buffer_path(%{buffers: %{active: buf}}) when is_pid(buf) do
    Buffer.file_path(buf)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp active_buffer_path(_ctx), do: nil

  @spec file_tree_root(Context.t()) :: String.t()
  defp file_tree_root(%{file_tree: %{tree: %{root: r}}}) when is_binary(r), do: r
  defp file_tree_root(_ctx), do: ""

  @spec build_status_bar(StatusBarData.t() | nil, Context.t()) ::
          Minga.RenderModel.UI.StatusBar.t() | nil
  defp build_status_bar(nil, _ctx), do: nil

  defp build_status_bar(status_bar_data, ctx) do
    StatusBarBuilder.build(status_bar_data, ctx.theme, ctx)
  end

  @spec shell_gui_payload(Context.t()) :: term()
  defp shell_gui_payload(%{shell: shell} = ctx) do
    if function_exported?(shell, :gui_payload, 1) do
      shell.gui_payload(ctx)
    else
      nil
    end
  rescue
    _ -> nil
  end
end
