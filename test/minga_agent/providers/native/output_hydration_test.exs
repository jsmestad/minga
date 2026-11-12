defmodule MingaAgent.Providers.Native.OutputHydrationTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Providers.Native.OutputHydration
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tools.OutputCapture
  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Anthropic

  @moduletag :tmp_dir

  test "multiple retained images reach the pinned wire encoder without exposing private references",
       %{tmp_dir: root} do
    store = start_store(Path.join(root, "supported"), "supported")
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy("image-page", 20_000)

    durable = [
      retained_message(store, bytes, "call-first", "first.png", %{marker: "kept"}),
      retained_message(store, bytes, "call-second", "second.png", %{})
    ]

    assistant =
      Context.assistant("",
        tool_calls: [
          ReqLLM.ToolCall.new("call-first", "read_file", ~s({"path":"first.png"})),
          ReqLLM.ToolCall.new("call-second", "read_file", ~s({"path":"second.png"}))
        ]
      )

    assert byte_size(bytes) > 64 * 1_024

    messages =
      for message <- [Context.user("Read the images"), assistant] ++ durable do
        assert {:ok, hydrated} = OutputHydration.hydrate(message, store, :supported)
        ReqLLMAdapter.request_message(hydrated)
      end

    request =
      Anthropic.encode_body(%Req.Request{
        options: [context: Context.new(messages), model: "exact-anthropic", stream: false]
      })

    wire = request |> Req.Steps.encode_body() |> Map.fetch!(:body) |> IO.iodata_to_binary()
    encoded = JSON.decode!(wire)
    results = List.last(encoded["messages"])["content"]

    assert Enum.map(results, & &1["tool_use_id"]) == ["call-first", "call-second"]

    for result <- results do
      assert result["type"] == "tool_result"

      assert Enum.any?(
               result["content"],
               &(&1["type"] == "text" and &1["text"] == "[image retained]")
             )

      assert [%{"source" => %{"type" => "base64", "media_type" => "image/png", "data" => data}}] =
               Enum.filter(result["content"], &(&1["type"] == "image"))

      assert Base.decode64!(data) == bytes
    end

    for message <- durable do
      assert [%Attachment{}] = message.metadata.output.attachments
      refute Enum.any?(message.content, &(&1.type == :image))
      refute String.contains?(wire, message.metadata.output.reference.token)
    end
  end

  test "both unsupported delivery reasons encode an explicit tool error without a store", %{
    tmp_dir: root
  } do
    store = start_store(Path.join(root, "unsupported"), "unsupported")
    durable = retained_message(store, png_bytes(), "call-refusal", "result.png", %{})

    for reason <- [:model_image_input, :tool_result_transport] do
      assert {:ok, hydrated} = OutputHydration.hydrate(durable, nil, {:unsupported, reason})
      assert hydrated.metadata.output == durable.metadata.output
      assert hydrated.metadata.image_tool_result_delivery == {:unsupported, reason}
      projected = ReqLLMAdapter.request_message(hydrated)

      request =
        Anthropic.encode_body(%Req.Request{
          options: [context: Context.new([projected]), model: "exact-anthropic", stream: false]
        })

      wire = request |> Req.Steps.encode_body() |> Map.fetch!(:body) |> IO.iodata_to_binary()
      assert [%{"role" => "user", "content" => [result]}] = JSON.decode!(wire)["messages"]
      assert result["tool_use_id"] == "call-refusal"
      assert result["is_error"] == true
      refute Enum.any?(result["content"], &(&1["type"] == "image"))
      assert Enum.map_join(result["content"], & &1["text"]) =~ "[image retained]"
      refute String.contains?(wire, durable.metadata.output.reference.token)
      refute Map.has_key?(projected.metadata, :image_tool_result_delivery)
    end
  end

  test "an unauthorized attachment remains a visible integrity failure", %{tmp_dir: root} do
    owner_store = start_store(Path.join(root, "owner"), "owner")
    other_store = start_store(Path.join(root, "other"), "other")
    durable = retained_message(owner_store, png_bytes(), "call-integrity", "result.png", %{})

    assert {:error, {:artifact_integrity_error, :unauthorized}} =
             OutputHydration.hydrate(durable, other_store, :supported)
  end

  defp retained_message(store, bytes, call_id, filename, metadata) do
    assert {:ok, captured} =
             OutputCapture.bytes(store, {:delivery, "checkpoint-" <> call_id, call_id}, bytes,
               media_type: "image/png"
             )

    assert {:ok, attachment} = Attachment.image(captured.reference, filename)

    assert {:ok, output} =
             Output.new("[image retained]", captured.capture, captured.selection,
               reference: captured.reference,
               attachments: [attachment],
               presentation: captured.presentation
             )

    Context.tool_result_message(
      "read_file",
      call_id,
      [ContentPart.text("[image retained]")],
      Map.merge(metadata, %{output: output})
    )
  end

  defp png_bytes, do: <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

  defp start_store(root, session_id) do
    quota =
      start_supervised!(
        Supervisor.child_spec(
          {ArtifactQuota, root: root},
          id: {:hydration_quota, make_ref()},
          restart: :temporary
        )
      )

    start_supervised!(
      Supervisor.child_spec(
        {ArtifactStore, root: root, quota: quota, session_id: session_id},
        id: {:hydration_store, make_ref()},
        restart: :temporary
      )
    )
  end
end
