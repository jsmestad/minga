defmodule MingaEditor.RenderModel.UI.Builder do
  @moduledoc false

  alias Minga.Buffer
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.BreadcrumbBuilder
  alias MingaEditor.RenderModel.UI.ThemeBuilder
  alias MingaEditor.RenderModel.UI.WhichKeyBuilder
  alias Minga.RenderModel

  @spec build_ui(Context.t()) :: RenderModel.UI.t()
  def build_ui(%Context{} = ctx) do
    file_path = active_buffer_path(ctx)
    root = file_tree_root(ctx)

    %RenderModel.UI{
      theme: ThemeBuilder.build(ctx.theme),
      breadcrumb: BreadcrumbBuilder.build(file_path, root),
      which_key: build_which_key(ctx)
    }
  end

  @spec build_which_key(Context.t()) :: Minga.RenderModel.UI.WhichKey.t() | nil
  defp build_which_key(%{shell_state: %{whichkey: wk}}) when not is_nil(wk) do
    WhichKeyBuilder.build(wk)
  end

  defp build_which_key(_ctx), do: nil

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
end
