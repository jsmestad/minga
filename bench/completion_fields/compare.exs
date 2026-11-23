# Compares one alternating pair set written by bench/completion_fields.exs (#3497).
#
#     elixir bench/completion_fields/compare.exs bench/completion_fields PREFIX
#
# PREFIX selects the runs PREFIX-{a,b}-{baseline,candidate}, for example `v1` or `c3`.
# It prints one Markdown row per item count and stage for each pair, and the response-to-popup totals.
# It also checks that every run reported the same result digest for each item count.

[dir, prefix] = System.argv()

read = fn label ->
  summary = dir |> Path.join("#{prefix}-#{label}/summary.json") |> File.read!() |> JSON.decode!()

  identity =
    dir |> Path.join("#{prefix}-#{label}/identity.json") |> File.read!() |> JSON.decode!()

  {summary, identity}
end

runs = Map.new(~w(a-baseline a-candidate b-candidate b-baseline), &{&1, read.(&1)})

for {label, {_s, id}} <- Enum.sort(runs) do
  IO.puts(
    "#{label}: commit #{id["commit"]} dirty=#{inspect(id["lib_dirty"])} sources=#{String.slice(id["completion_sources_sha256"], 0, 12)}"
  )
end

{a_base, _} = runs["a-baseline"]

for count <- a_base |> Map.keys() |> Enum.sort_by(&String.to_integer/1) do
  digests = runs |> Enum.map(fn {_l, {s, _}} -> s[count]["digest"] end) |> Enum.uniq()

  IO.puts(
    "items #{count}: #{length(digests)} distinct digest(s) #{String.slice(hd(digests), 0, 16)}"
  )
end

stages = ~w(parse transfer install visible filter select accept)
ms = fn us -> :erlang.float_to_binary(us / 1000, decimals: if(us >= 100_000, do: 0, else: 2)) end
fmt = fn s -> Enum.map_join(~w(us_p10 us_p50 us_p90 us_p95), " / ", &ms.(s[&1])) end

int = fn n ->
  n
  |> Integer.to_string()
  |> String.reverse()
  |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
  |> String.reverse()
end

for {pair, base_label, cand_label} <- [
      {"A", "a-baseline", "a-candidate"},
      {"B", "b-baseline", "b-candidate"}
    ] do
  {base, _} = runs[base_label]
  {cand, _} = runs[cand_label]
  IO.puts("\nPair #{pair}\n")

  IO.puts(
    "| Items | Stage | n | Baseline ms p10 / p50 / p90 / p95 | Candidate ms p10 / p50 / p90 / p95 | p50 change | Baseline reductions p50 | Candidate reductions p50 | Ratio | Retained words p50 baseline / candidate |"
  )

  IO.puts("|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|")

  for count <- base |> Map.keys() |> Enum.sort_by(&String.to_integer/1), stage <- stages do
    b = base[count]["stages"][stage]
    c = cand[count]["stages"][stage]

    change =
      if b["us_p50"] == 0, do: "n/a", else: "#{round((c["us_p50"] / b["us_p50"] - 1) * 100)}%"

    ratio =
      if b["reductions_p50"] == 0,
        do: "n/a",
        else: :erlang.float_to_binary(c["reductions_p50"] / b["reductions_p50"], decimals: 2)

    words =
      if b["words_p50"] == 0, do: "", else: "#{int.(b["words_p50"])} / #{int.(c["words_p50"])}"

    IO.puts(
      "| #{int.(String.to_integer(count))} | #{stage} | #{b["n"]} / #{c["n"]} | #{fmt.(b)} | #{fmt.(c)} | #{change} | #{int.(b["reductions_p50"])} | #{int.(c["reductions_p50"])} | #{ratio} | #{words} |"
    )
  end
end

# Response to first visible popup: parse + transfer + install + visible, summed per sample.
pct = fn sorted, p -> Enum.at(sorted, max(ceil(p / 100 * length(sorted)), 1) - 1) end

popup = fn label ->
  dir
  |> Path.join("#{prefix}-#{label}/samples.csv.gz")
  |> File.stream!([:compressed])
  |> Stream.drop(1)
  |> Stream.map(&String.split(String.trim(&1), ","))
  |> Stream.filter(fn [_i, _n, stage | _] -> stage in ~w(parse transfer install visible) end)
  |> Enum.group_by(fn [items, n | _] -> {String.to_integer(items), n} end, fn [_, _, _, _, us | _] ->
    String.to_integer(us)
  end)
  |> Enum.group_by(fn {{items, _n}, _} -> items end, fn {_, uss} -> Enum.sum(uss) end)
  |> Map.new(fn {items, totals} -> {items, Enum.sort(totals)} end)
end

IO.puts(
  "\nResponse to visible popup (parse + transfer + install + visible), ms p10 / p50 / p90 / p95\n"
)

IO.puts("| Items | A baseline | A candidate | B baseline | B candidate |")
IO.puts("|---:|---:|---:|---:|---:|")
tables = Map.new(~w(a-baseline a-candidate b-baseline b-candidate), &{&1, popup.(&1)})

for items <- tables["a-baseline"] |> Map.keys() |> Enum.sort() do
  cells =
    Enum.map_join(~w(a-baseline a-candidate b-baseline b-candidate), " | ", fn l ->
      s = tables[l][items]
      Enum.map_join([10, 50, 90, 95], " / ", &ms.(pct.(s, &1)))
    end)

  IO.puts("| #{int.(items)} | #{cells} |")
end
