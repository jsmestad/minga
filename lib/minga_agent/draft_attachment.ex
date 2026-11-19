defmodule MingaAgent.DraftAttachment do
  @moduledoc "Captures and reads immutable text for an explicit composer attachment."

  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.Capture
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.ArtifactStore.Fetched
  alias MingaAgent.ArtifactStore.Stored
  alias MingaAgent.DraftSnapshot
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Policy.Limits
  alias MingaAgent.TokenEstimator
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias ReqLLM.Message.ContentPart

  @max_bytes 32_768
  @media_type "text/plain"

  @doc "Returns the maximum exact text payload admitted for one snapshot."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @type identity :: {String.t(), String.t()}
  @type text_snapshot :: {DraftSnapshot.source_kind(), String.t(), String.t(), String.t()}

  @doc "Labels how a retained text snapshot was captured."
  @spec snapshot_label(DraftSnapshot.source_kind()) :: String.t()
  def snapshot_label(:selection), do: "Selection snapshot"
  def snapshot_label(:buffer), do: "Buffer snapshot"
  def snapshot_label(:file), do: "File snapshot"
  def snapshot_label(:diagnostics), do: "Diagnostics snapshot"

  @doc "Returns the stable retained identity and captured revision of a snapshot."
  @spec identity(DraftSnapshot.attachment()) :: identity() | nil
  def identity({_kind, _source, _label, revision, {:snapshot, %Reference{token: token}}}),
    do: {token, revision}

  def identity(_attachment), do: nil

  @doc "Adds captured text verbatim after the prompt and checks the selected route's advertised input limit."
  @spec append_to_prompt(
          String.t() | [ContentPart.t()],
          [{DraftSnapshot.attachment(), String.t()}],
          ModelSelection.t() | nil
        ) ::
          {:ok, [ContentPart.t()]}
          | {:error, :attachment_route_unsupported | :draft_attachments_too_large}
  def append_to_prompt(prompt, snapshots, %ModelSelection{policy: %{limits: limits}, route: route}) do
    case route.metadata do
      %{modalities: %{input: inputs}} when is_list(inputs) ->
        if :text in inputs,
          do: append_text_parts(prompt, snapshots, limits),
          else: {:error, :attachment_route_unsupported}

      _not_advertised ->
        append_text_parts(prompt, snapshots, limits)
    end
  end

  def append_to_prompt(_prompt, _snapshots, _selection),
    do: {:error, :attachment_route_unsupported}

  @spec append_text_parts(
          String.t() | [ContentPart.t()],
          [{DraftSnapshot.attachment(), String.t()}],
          Limits.t()
        ) ::
          {:ok, [ContentPart.t()]} | {:error, :draft_attachments_too_large}
  defp append_text_parts(prompt, snapshots, %Limits{
         input: input,
         context: context,
         request_output: output
       }) do
    parts = if is_binary(prompt), do: [ContentPart.text(prompt)], else: prompt

    parts =
      parts ++
        Enum.map(snapshots, fn {{kind, _source, label, _revision, _capture}, text} ->
          ContentPart.text(
            IO.iodata_to_binary(["\n\n", snapshot_label(kind), ": ", label, "\n", text])
          )
        end)

    estimated = Enum.reduce(parts, 0, &estimate_text_part/2)

    if (is_integer(input) and estimated > input) or
         (is_integer(context) and estimated + output > context),
       do: {:error, :draft_attachments_too_large},
       else: {:ok, parts}
  end

  @spec estimate_text_part(ContentPart.t(), non_neg_integer()) :: non_neg_integer()
  defp estimate_text_part(%ContentPart{type: :text, text: text}, total),
    do: total + TokenEstimator.estimate_string(text)

  defp estimate_text_part(_other, total), do: total

  @doc "Stages exact text with a delivery pin. The record writer transfers or releases this pin."
  @spec capture_text(GenServer.server(), text_snapshot()) ::
          {:ok, DraftSnapshot.attachment(), {:delivery, String.t(), String.t()}}
          | {:error, term()}
  def capture_text(store, {kind, source, label, text})
      when kind in [:selection, :buffer, :file, :diagnostics] and is_binary(source) and
             is_binary(label) and
             is_binary(text) and byte_size(text) in 1..@max_bytes do
    key =
      {:delivery, "composer-attachment",
       Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}

    with true <- String.valid?(text) || {:error, :invalid_attachment_text},
         {:ok, spec} <-
           CaptureSpec.new(
             delivery_key: key,
             owner_pid: self(),
             media_type: @media_type,
             mode: :bytes,
             expected_bytes: byte_size(text)
           ),
         {:ok, capture} <- ArtifactStore.begin(store, spec),
         {:ok, reference} <- write_capture(store, capture, text, key) do
      {:ok, {kind, source, label, reference.sha256, {:snapshot, reference}}, key}
    end
  end

  def capture_text(_store, _snapshot), do: {:error, :invalid_attachment_text}

  @doc "Reads only complete, matching bytes from this record. It never reopens the source."
  @spec read_text(GenServer.server(), DraftSnapshot.attachment()) ::
          {:ok, String.t()} | {:error, term()}
  def read_text(store, {_kind, _source, _label, revision, {:snapshot, reference}})
      when is_struct(reference, Reference) do
    case reference do
      %Reference{bytes: bytes, media_type: @media_type, sha256: ^revision}
      when bytes in 1..@max_bytes ->
        with {:ok, range} <- Range.new(:full, :bytes, 0, bytes, bytes),
             {:ok, %Fetched{capture: :complete, reference: ^reference, bytes: text}} <-
               ArtifactStore.fetch(store, reference, range),
             true <- String.valid?(text) do
          {:ok, text}
        else
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_attachment_snapshot}
        end

      _invalid ->
        {:error, :invalid_attachment_snapshot}
    end
  end

  def read_text(_store, _attachment), do: {:error, :unsupported_attachment}

  @spec write_capture(GenServer.server(), Capture.t(), binary(), tuple()) ::
          {:ok, Reference.t()} | {:error, term()}
  defp write_capture(store, capture, text, key) do
    with {:ok, _progress} <- ArtifactStore.append(store, capture, text),
         {:ok, %Stored{capture: :complete, reference: reference}} <-
           ArtifactStore.finish(store, capture, :complete) do
      {:ok, reference}
    else
      {:ok, %Stored{capture: {:incomplete, reason}}} ->
        _release = ArtifactStore.release(store, key)
        {:error, reason}

      {:error, _reason} = error ->
        _cancel = ArtifactStore.cancel(store, capture)
        error
    end
  end
end
