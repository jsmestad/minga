defmodule Minga.Bench.ProvenanceEdits do
  @moduledoc """
  Authorship cost as a buffer's history grows (#4048).

  Builds `Minga.Buffer.Provenance` values with about 10, 100, 1,000 and 10,000 authorship runs over a 200 KB document, alternating your edits and two Minga tasks' steps, then times:

    * `edit`: one single-byte insertion or deletion at a random offset, the cost every keystroke adds to the buffer process.
    * `author_at`: the author of the byte at a random offset.
    * `spans`: the authorship of a 60-line window (about 3 KB), the gutter's query.
    * `revert`: undoing one of your groups with a handful of runs, applied to the document.

  Each cell reports the median of many samples in microseconds. Edit, lookup and window costs should stay roughly flat while runs grow a thousandfold; `revert` also pays one pass over the document.

  Run with:

      MIX_ENV=test mix run bench/provenance_edits.exs

  The script prints a table and writes nothing. Put the numbers in the PR description, with the commit they ran on.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Provenance

  @document_bytes 200_000
  @samples 200
  @run_targets [10, 100, 1_000, 10_000]

  @spec run() :: :ok
  def run do
    :rand.seed(:exsss, {4048, 7, 11})
    IO.puts("runs     edit_us  author_at_us  spans_us  revert_us")

    for target <- @run_targets do
      {prov, text, you} = build(target)
      runs = length(Provenance.runs(prov))
      document = Document.new(text)

      edit = median_us(fn -> random_edit(prov, you, text) end)
      author = median_us(fn -> Provenance.author_at(prov, :rand.uniform(@document_bytes) - 1) end)
      spans = median_us(fn -> window(prov) end)
      revert = median_us(fn -> {:ok, _doc, _first, _prov} = Provenance.revert(prov, you, document) end, 5)

      IO.puts(
        String.pad_trailing(Integer.to_string(runs), 9) <>
          format(edit, 9) <> format(author, 14) <> format(spans, 10) <> format(revert, 11)
      )
    end

    :ok
  end

  # Inserts one byte per step at spread offsets, rotating between you and two Minga tasks. Each
  # insertion into a run splits it, so every step adds about two runs. Returns the provenance, its
  # text, and your last group.
  @spec build(pos_integer()) :: {Provenance.t(), binary(), Provenance.group_id()}
  defp build(target) do
    text =
      :binary.copy("abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmn\n", div(@document_bytes, 51))

    authors = [{:you, nil}, {{:minga, "t1"}, :step}, {{:minga, "t2"}, :step}]
    steps = max(div(target, 2), 3)

    {prov, text, you} =
      authors
      |> Stream.cycle()
      |> Enum.take(steps)
      |> Enum.with_index()
      |> Enum.reduce({Provenance.new(byte_size(text)), text, nil}, fn {{author, key}, n},
                                                                        {prov, text, you} ->
        key = if key == :step, do: {elem(author, 0), elem(author, 1), "call-#{n}"}, else: nil
        {group, prov} = Provenance.open_group(prov, author, key)
        offset = rem(n * 7919, byte_size(text))
        prov = Provenance.edit(prov, group, offset, "", "Z")
        text = binary_part(text, 0, offset) <> "Z" <> binary_part(text, offset, byte_size(text) - offset)
        {prov, text, if(author == :you, do: group, else: you)}
      end)

    {prov, text, you}
  end

  @spec random_edit(Provenance.t(), Provenance.group_id(), binary()) :: Provenance.t()
  defp random_edit(prov, group, text) do
    offset = :rand.uniform(byte_size(text) - 1) - 1

    if :rand.uniform(2) == 1,
      do: Provenance.edit(prov, group, offset, "", "y"),
      else: Provenance.edit(prov, group, offset, binary_part(text, offset, 1), "")
  end

  @spec window(Provenance.t()) :: [Provenance.span()]
  defp window(prov) do
    from = :rand.uniform(@document_bytes - 4_000)
    Provenance.spans(prov, from, from + 3_060)
  end

  # Times `reps` calls per sample, so the clock's microsecond resolution does not hide the cost.
  @spec median_us((-> term()), pos_integer()) :: float()
  defp median_us(fun, reps \\ 50) do
    times =
      for _ <- 1..@samples do
        {microseconds, _result} = :timer.tc(fn -> Enum.each(1..reps, fn _ -> fun.() end) end)
        microseconds / reps
      end

    times |> Enum.sort() |> Enum.at(div(@samples, 2))
  end

  @spec format(float(), pos_integer()) :: String.t()
  defp format(value, width),
    do: value |> :erlang.float_to_binary(decimals: 1) |> String.pad_leading(width)
end

Minga.Bench.ProvenanceEdits.run()
