defmodule MingaEditor.ConfigCompletionIntegrationTest do
  use Minga.Test.EditorCase, async: true

  alias MingaEditor.State.ModalOverlay

  @moduletag :tmp_dir

  describe "config DSL completion" do
    test "typing set colon in insert mode opens option completion", %{tmp_dir: tmp_dir} do
      ctx = start_editor("", file_path: tmp_project_config_path(tmp_dir))

      state = send_keys_sync(ctx, "iset :")
      completion = ModalOverlay.completion(state)

      assert completion != nil
      assert Enum.any?(completion.filtered, fn item -> item.label == ":tab_width" end)
      assert completion.filter_text == ""
    end

    test "typing set colon in cua mode opens option completion", %{tmp_dir: tmp_dir} do
      ctx = start_editor("", file_path: tmp_project_config_path(tmp_dir), editing_model: :cua)

      state = send_keys_sync(ctx, "set :")
      completion = ModalOverlay.completion(state)

      assert completion != nil
      assert Enum.any?(completion.filtered, fn item -> item.label == ":tab_width" end)
      assert completion.filter_text == ""
    end
  end

  @spec tmp_project_config_path(String.t()) :: String.t()
  defp tmp_project_config_path(tmp_dir) do
    path = Path.join(tmp_dir, ".minga.exs")
    File.write!(path, "")
    path
  end
end
