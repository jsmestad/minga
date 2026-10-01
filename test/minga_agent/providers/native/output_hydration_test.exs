defmodule MingaAgent.Providers.Native.OutputHydrationTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Providers.Native.OutputHydration
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tools.OutputCapture
  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Anthropic

  @moduletag :tmp_dir

  test "hydrates a larger-than-page image exactly and the pinned Anthropic encoder consumes it",
       %{
         tmp_dir: root
       } do
    store = start_store(Path.join(root, "supported"), "supported")
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy("image-page", 20_000)
    durable = retained_message(store, bytes, "call-image", "result.png", %{marker: "kept"})

    messages = [
      Context.user("Read the image"),
      Context.assistant("",
        tool_calls: [
          %ReqLLM.ToolCall{
            id: "call-image",
            type: "function",
            function: %{name: "read_file", arguments: ~s({\"path\":\"result.png\"})}
          }
        ]
      ),
      durable
    ]

    assert byte_size(bytes) > 64 * 1_024

    assert {:ok, hydrated_messages} = OutputHydration.hydrate(messages, store, :supported)
    hydrated = Enum.find(hydrated_messages, &(&1.tool_call_id == "call-image"))

    assert hydrated.name == "read_file"
    assert hydrated.tool_call_id == "call-image"
    assert hydrated.metadata.marker == "kept"
    assert Enum.any?(hydrated.content, &(&1.type == :text and &1.text == "[image retained]"))
    assert Enum.any?(hydrated.content, &(&1.type == :image and &1.data == bytes))
    refute Enum.any?(durable.content, &(&1.type == :image))

    request =
      Anthropic.encode_body(%Req.Request{
        options: [
          context: Context.new(hydrated_messages),
          model: "exact-anthropic",
          stream: false
        ]
      })

    encoded_tool_result =
      request.options[:json][:messages]
      |> List.last()
      |> Map.fetch!(:content)
      |> List.first()

    assert encoded_tool_result[:type] == "tool_result"
    assert encoded_tool_result[:tool_use_id] == "call-image"

    assert Enum.any?(encoded_tool_result[:content], fn
             %{type: "image", source: %{type: "base64", media_type: "image/png", data: data}} ->
               Base.decode64!(data) == bytes

             _block ->
               false
           end)
  end

  test "unsupported restored history becomes an explicit tool error without fetching", %{
    tmp_dir: root
  } do
    store = start_store(Path.join(root, "unsupported"), "unsupported")
    durable = retained_message(store, png_bytes(), "call-refusal", "result.png", %{})

    assert {:ok, [projected]} =
             OutputHydration.hydrate(
               [durable],
               nil,
               {:unsupported, :tool_result_transport}
             )

    assert projected.name == durable.name
    assert projected.tool_call_id == durable.tool_call_id
    assert projected.metadata.is_error == true
    assert projected.metadata.output == durable.metadata.output

    assert projected.metadata.image_tool_result_delivery ==
             {:unsupported, :tool_result_transport}

    text = projected.content |> Enum.map_join("", &(&1.text || ""))
    assert text =~ "[image retained]"
    assert text =~ "selected protocol does not support images in tool results"
    refute Enum.any?(projected.content, &(&1.type == :image))
  end

  test "an unauthorized attachment remains a visible integrity failure", %{tmp_dir: root} do
    owner_store = start_store(Path.join(root, "owner"), "owner")
    other_store = start_store(Path.join(root, "other"), "other")
    durable = retained_message(owner_store, png_bytes(), "call-integrity", "result.png", %{})

    assert {:error, {:artifact_integrity_error, :unauthorized}} =
             OutputHydration.hydrate([durable], other_store, :supported)
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
