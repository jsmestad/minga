defmodule MingaAgent.Tools.FetchOutputTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tools.FetchOutput

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    quota =
      start_supervised!(
        Supervisor.child_spec({ArtifactQuota, root: root},
          id: {:fetch_quota, make_ref()},
          restart: :temporary
        )
      )

    store =
      start_supervised!(
        Supervisor.child_spec(
          {ArtifactStore, root: root, quota: quota, session_id: "fetch-session"},
          id: {:fetch_store, make_ref()},
          restart: :temporary
        )
      )

    %{store: store, context: Context.new(project_root: root, artifact_store: store)}
  end

  test "a byte page splitting a UTF-8 codepoint is returned as explicit base64", %{
    store: store,
    context: context
  } do
    reference = store_bytes(store, "unicode", "a€b", "text/plain")

    assert {:ok, output} =
             FetchOutput.execute(context, %{
               "reference" => encode_reference(reference),
               "unit" => "bytes",
               "start" => 2,
               "count" => 2
             })

    assert output.capture == :complete
    assert output.presentation == :complete
    assert output.selection.start == 2
    assert output.selection.count == 2
    assert output.view == "[base64; bytes=2]\n" <> Base.encode64(<<0x82, 0xAC>>)
  end

  test "arbitrary binary media is returned without unsupported-content errors", %{
    store: store,
    context: context
  } do
    bytes = <<0, 255, 1, 254>>
    reference = store_bytes(store, "binary", bytes, "application/octet-stream")

    assert {:ok, output} =
             FetchOutput.execute(context, %{
               "reference" => encode_reference(reference),
               "unit" => "bytes",
               "start" => 0,
               "count" => byte_size(bytes)
             })

    assert output.view == "[base64; bytes=4]\n" <> Base.encode64(bytes)
  end

  defp store_bytes(store, call_id, bytes, media_type) do
    {:ok, spec} =
      CaptureSpec.new(
        media_type: media_type,
        mode: :bytes,
        owner_pid: self(),
        delivery_key: {:delivery, "checkpoint-1", call_id}
      )

    {:ok, capture} = ArtifactStore.begin(store, spec)
    assert {:ok, _progress} = ArtifactStore.append(store, capture, bytes)
    assert {:ok, stored} = ArtifactStore.finish(store, capture, :complete)
    stored.reference
  end

  defp encode_reference(reference) do
    %{
      "token" => reference.token,
      "media_type" => reference.media_type,
      "bytes" => reference.bytes,
      "items" => reference.items,
      "sha256" => reference.sha256
    }
  end
end
