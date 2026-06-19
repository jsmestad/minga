defmodule MingaKnowledgeGraph.Briefing do
  @moduledoc """
  Builds the briefing prompt and renders the briefing float panel.

  The Tracker drives the lifecycle (kick off `Minga.Extension.AI.stream/2`,
  feed chunks back here); this module owns the prompt and the panel
  presentation only.

  # ponytail: the prompt includes the file's on-disk contents only, no
  # caller-graph traversal. Add neighbors/callers if briefings feel shallow.
  """

  alias Minga.Extension.Panel

  @extension_name :minga_knowledge_graph
  @panel_id :briefing
  @max_content_chars 8_000

  @system_prompt """
  You are a senior engineer giving a colleague a 90-second briefing on a file
  they have not worked in before. They already know Elixir and OTP, so do not
  explain language basics. In under 180 words, explain: what this file is
  responsible for, the key data flow through it, and the one or two things to
  watch out for when changing it. Be concrete and specific to this file. No
  preamble, no restating the file name.
  """

  @doc "Builds the chat messages for a briefing on `path` with on-disk `content`."
  @spec messages(String.t(), String.t()) :: [%{role: String.t(), content: String.t()}]
  def messages(path, content) do
    [
      %{role: "system", content: @system_prompt},
      %{role: "user", content: "File: #{path}\n\n```\n#{truncate(content)}\n```"}
    ]
  end

  @doc "Renders the briefing panel for the given lifecycle status."
  @spec render(String.t(), {:generating} | {:text, String.t()} | {:error, term()}) :: :ok
  def render(path, status) do
    Panel.set(@extension_name, @panel_id, %{
      title: "Briefing: #{Path.basename(path)}",
      position: :float,
      size: {:lines, 14},
      visible: true,
      content: [{:text, body(status)}]
    })
  end

  @doc "Hides the briefing panel."
  @spec dismiss() :: :ok
  def dismiss, do: Panel.hide(@extension_name, @panel_id)

  @spec body({:generating} | {:text, String.t()} | {:error, term()}) :: String.t()
  defp body({:generating}), do: "Generating briefing…"
  defp body({:text, ""}), do: "Generating briefing…"
  defp body({:text, text}), do: text
  defp body({:error, _reason}), do: "Could not generate a briefing right now."

  @spec truncate(String.t()) :: String.t()
  defp truncate(content) when byte_size(content) <= @max_content_chars, do: content

  defp truncate(content) do
    binary_slice(content, 0, @max_content_chars) <> "\n\n[file truncated]"
  end
end
