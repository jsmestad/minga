defmodule Minga.Bench.CompletionFields do
  @moduledoc """
  Completion preparation cost on the complete consumer path (#3497).

  Each sample replays one LSP completion response through the production topology. A fresh worker process stands in for the completion Task, and a fresh receiver process stands in for the Editor:

    * `parse`: the Task's work, `ProviderBatch.from_response/6` on the raw LSP response.
    * `transfer`: sending the parsed batch to the receiver, which copies it into the receiver's heap, until the receiver acknowledges it.
    * `install`: the Editor's work when the batch arrives, `Session.accept_batch/2`, then `Completion.new/3` and `Completion.filter/2` with the prefix typed so far (`install_session_completion/3`).
    * `visible`: building the popup model with `CompletionBuilder.build/1` and encoding it with `CompletionEncoder.encode/2`.
    * `filter`: one typed character, `Completion.filter/2` plus the popup model and its encoding. Samples cover a fixed keystroke sequence.
    * `select`: one selection move, `Completion.move_down/1`, plus the popup model and its selection encoding. Samples cover 20 moves.
    * `accept`: `Completion.accept/1` for the selected item and the resulting buffer edit on a started buffer, placed as `CompletionHandling` places it.

  Every stage records wall microseconds and the reductions of the process doing the work (a deterministic work count). `parse` and `install` also record the flat heap size of their result in words (retained memory). The receiver checks each result and adds it to a digest: ranked wire ids, labels, match ranges, counts, the selected item and its documentation, the accepted edit and the edited buffer content. Baseline and candidate runs must report the same digest for every item count.

  The script uses only public functions present on both the baseline and the candidate commit, so it runs unchanged on either. Run it once per commit, alternating the order across pairs:

      MIX_ENV=test mix run bench/completion_fields.exs OUT_DIR [--quick]

  `--quick` limits the run to 0 and 10,000 items. Each run writes `samples.csv`, `summary.json` and `identity.json` into OUT_DIR.
  """

  alias Minga.Editing.Completion
  alias Minga.Editing.Completion.Item
  alias Minga.Editing.Completion.ProviderBatch
  alias Minga.Editing.Completion.Session
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias MingaEditor.RenderModel.UI.CompletionBuilder

  @counts [0, 100, 1_000, 10_000]
  @quick_counts [0, 10_000]
  @max_samples %{0 => 40, 100 => 40, 1_000 => 30, 10_000 => 20}
  @budget_us 60_000_000
  @warmup 2
  @install_prefix "h"
  @keystrokes ["ha", "han", "hand", "handl", "handle", "handle_", "hdlev"]
  @select_moves 20
  @trigger {10, 4}
  @edit_line 10

  # ── Fixture ────────────────────────────────────────────────────────────────

  @doc "Builds a deterministic LSP CompletionList with `count` items."
  @spec response(non_neg_integer()) :: map()
  def response(count) do
    items =
      Enum.flat_map(0..(count - 1)//1, fn i ->
        raw = raw_item(i, count)
        # Every 50th item is followed by a true duplicate, which the index collapses.
        if rem(i, 50) == 49, do: [raw, raw], else: [raw]
      end)
      |> Enum.take(count)

    %{"isIncomplete" => false, "items" => items}
  end

  defp raw_item(i, count) do
    label = label(i)

    base = %{
      "label" => label,
      "kind" => rem(i, 25) + 1,
      "detail" => "(#{label}, term(), keyword()) :: {:ok, t()} | {:error, term()}",
      "sortText" => String.pad_leading(Integer.to_string(rem(i * 7919, max(count, 1))), 6, "0"),
      "insertTextFormat" => 2,
      "data" => %{"module" => "Bench.Module#{rem(i, 97)}", "index" => i}
    }

    base
    |> put_filter_text(i)
    |> put_documentation(i, label)
    |> put_edit(i, label)
    |> put_additional_edits(i)
    |> put_preselect(i)
  end

  # ASCII, Latin with accents, CJK, an uppercase start with an emoji, and Greek capitals whose
  # whole-string lowercase differs from the per-character lowercase (final sigma).
  defp label(i) do
    case rem(i, 5) do
      0 -> "handle_event_#{i}"
      1 -> "handle_évènement_#{i}"
      2 -> "handle_字段_#{i}"
      3 -> "Handle😀Emoji_#{i}"
      4 -> "handleΣΑΣ_#{i}"
    end
  end

  # Every 7th item filters on text different from its label, so its label has no match ranges.
  defp put_filter_text(raw, i) when rem(i, 7) == 0,
    do: Map.put(raw, "filterText", "handle_alt_#{i}")

  defp put_filter_text(raw, _i), do: Map.put(raw, "filterText", raw["label"])

  # Long markdown documentation with surrounding whitespace. Every 5th item has none (it needs
  # completionItem/resolve), and every 13th has a plaintext string.
  defp put_documentation(raw, i, _label) when rem(i, 5) == 2, do: raw

  defp put_documentation(raw, i, label) when rem(i, 13) == 0,
    do: Map.put(raw, "documentation", "\n  #{label} plaintext docs.\n" <> doc_body(i) <> "  \n")

  defp put_documentation(raw, i, label) do
    Map.put(raw, "documentation", %{
      "kind" => "markdown",
      "value" => "\n\n# `#{label}/2`\n\n" <> doc_body(i) <> "\n\n"
    })
  end

  defp doc_body(i) do
    paragraph =
      "Handles the event and returns the updated state. Accepts `:timeout`, `:retries` and " <>
        "`:on_error` options. Raises `ArgumentError` when the event is malformed — " <>
        "ünïcödé text included.\n\n    iex> handle(#{i}, retries: 3)\n    {:ok, %State{}}\n\n"

    String.duplicate(paragraph, 12)
  end

  # Snippet text edits, InsertReplaceEdit on every 3rd item, plain insertText on every 9th.
  defp put_edit(raw, i, label) when rem(i, 9) == 0,
    do: Map.put(raw, "insertText", "#{label}(${1:event}, ${2:opts})$0")

  defp put_edit(raw, i, label) when rem(i, 3) == 0 do
    Map.put(raw, "textEdit", %{
      "insert" => range(@edit_line, 4, @edit_line, 7),
      "replace" => range(@edit_line, 4, @edit_line, 7),
      "newText" => "#{label}(${1:event}, ${2:opts})$0"
    })
  end

  defp put_edit(raw, _i, label) do
    Map.put(raw, "textEdit", %{
      "range" => range(@edit_line, 4, @edit_line, 7),
      "newText" => "#{label}(${1:event}, ${2:opts})$0"
    })
  end

  defp put_additional_edits(raw, i) when rem(i, 2) == 0 do
    Map.put(raw, "additionalTextEdits", [
      %{"range" => range(0, 0, 0, 0), "newText" => "alias Bench.Module#{rem(i, 97)}\n"}
    ])
  end

  defp put_additional_edits(raw, _i), do: raw

  defp put_preselect(raw, 42), do: Map.put(raw, "preselect", true)
  defp put_preselect(raw, _i), do: raw

  defp range(sl, sc, el, ec) do
    %{
      "start" => %{"line" => sl, "character" => sc},
      "end" => %{"line" => el, "character" => ec}
    }
  end

  defp buffer_text do
    lines = for n <- 0..19, do: if(n == @edit_line, do: "    han", else: "  line_#{n} = :ok")
    Enum.join(lines, "\n") <> "\n"
  end

  # ── Sample ─────────────────────────────────────────────────────────────────

  # One sample: the Task process parses and sends; the receiver installs, renders, filters,
  # selects and accepts. Returns `{measurements, digest}`.
  defp sample(response) do
    parent = self()
    session_id = make_ref()
    request_ref = make_ref()
    client = spawn(fn -> receive(do: (:stop -> :ok)) end)
    buffer = start_buffer()

    receiver =
      spawn(fn ->
        receive do
          {:batch, batch, sender} ->
            send(sender, :received)
            result = editor_stages(batch, session_id, request_ref, client, buffer)
            send(parent, {:editor_done, self(), result})
        end
      end)

    task =
      spawn(fn ->
        {parse, batch} =
          measure(fn ->
            ProviderBatch.from_response(
              session_id,
              1,
              {:lsp_client, client},
              client,
              request_ref,
              response
            )
          end)

        parse = Map.put(parse, :words, :erts_debug.flat_size(batch))
        t0 = System.monotonic_time(:microsecond)
        send(receiver, {:batch, batch, self()})
        receive(do: (:received -> :ok))
        transfer = %{us: System.monotonic_time(:microsecond) - t0, reductions: 0, words: 0}
        send(parent, {:task_done, self(), parse, transfer})
      end)

    task_ref = Process.monitor(task)
    receiver_ref = Process.monitor(receiver)

    {parse, transfer} =
      receive do
        {:task_done, ^task, parse, transfer} -> {parse, transfer}
        {:DOWN, ^task_ref, :process, _, reason} when reason != :normal -> exit(reason)
      end

    {stages, digest} =
      receive do
        {:editor_done, ^receiver, result} -> result
        {:DOWN, ^receiver_ref, :process, _, reason} when reason != :normal -> exit(reason)
      end

    Process.demonitor(task_ref, [:flush])
    Process.demonitor(receiver_ref, [:flush])

    send(client, :stop)
    GenServer.stop(buffer)
    {[{:parse, parse}, {:transfer, transfer} | stages], digest}
  end

  defp start_buffer do
    {:ok, buffer} = GenServer.start(Minga.Buffer.Process, content: buffer_text())
    buffer
  end

  defp editor_stages(batch, session_id, request_ref, client, buffer) do
    provider_id = batch.provider_id

    session =
      Session.new(session_id, 1, buffer, 0, @trigger)
      |> Session.register_requests([{provider_id, client, request_ref}])

    {install, {_session, completion}} =
      measure(fn ->
        {:ok, session} = Session.accept_batch(session, batch)

        completion =
          Session.index(session)
          |> Completion.new(@trigger, session.selected_item_id)
          |> Completion.filter(@install_prefix)

        {session, completion}
      end)

    install = Map.put(install, :words, :erts_debug.flat_size(completion))

    {visible, {model, caches}} = measure(fn -> render(completion, Caches.new()) end)
    install_digest = completion_digest(completion, model)

    {filters, {completion, caches, filter_digest}} =
      Enum.reduce(@keystrokes, {[], {completion, caches, []}}, fn prefix,
                                                                  {acc, {completion, caches, d}} ->
        {m, {completion, {model, caches}}} =
          measure(fn ->
            completion = Completion.filter(completion, prefix)
            {completion, render(completion, caches)}
          end)

        {[{:filter, m} | acc], {completion, caches, [completion_digest(completion, model) | d]}}
      end)

    # Selection moves run on the last plain prefix, `handle_`, not the fuzzy query.
    completion = Completion.filter(completion, "handle_")
    {_model, caches} = render(completion, caches)

    {selects, {completion, _caches, select_digest}} =
      Enum.reduce(1..@select_moves, {[], {completion, caches, []}}, fn _n,
                                                                       {acc,
                                                                        {completion, caches, d}} ->
        {m, {completion, {model, caches}}} =
          measure(fn ->
            completion = Completion.move_down(completion)
            {completion, render(completion, caches)}
          end)

        selected = Map.get(normalized_wire_ids(completion), model.selected_item_id, "")
        {[{:select, m} | acc], {completion, caches, [{selected, model.documentation} | d]}}
      end)

    {accept, accepted} =
      measure(fn ->
        accepted = Completion.accept(completion)
        apply_accepted(buffer, completion, accepted)
        accepted
      end)

    digest = %{
      install: install_digest,
      filters: Enum.reverse(filter_digest),
      selects: Enum.reverse(select_digest),
      accepted: accepted_digest(accepted, normalized_wire_ids(completion)),
      buffer: Minga.Buffer.content(buffer)
    }

    stages =
      Enum.concat([
        [{:install, install}, {:visible, visible}],
        Enum.reverse(filters),
        Enum.reverse(selects),
        [{:accept, accept}]
      ])

    {stages, digest}
  end

  defp render(%Completion{} = completion, caches) do
    model =
      CompletionBuilder.build(%{
        completion: completion,
        windows: %{active: 1, map: %{}},
        layout: %{window_layouts: %{}}
      })

    {_command, caches} = CompletionEncoder.encode(model, caches)
    {model, caches}
  end

  # Wire ids and source labels embed the stand-in client pid, which differs per sample and per
  # run. The digest replaces each with a pid-free equivalent so runs on different commits compare.
  defp completion_digest(completion, model) do
    ids = normalized_wire_ids(completion)

    {completion.filter_text, completion.matched_count, completion.total_count,
     completion.incomplete?,
     Enum.map(
       completion.filtered,
       &{Map.fetch!(ids, Item.wire_id(&1)), &1.label, &1.kind, &1.match_ranges, &1.detail,
        &1.documentation, &1.insert_text, &1.text_edit, &1.preselect}
     ), Map.get(ids, model.selected_item_id, model.selected_item_id), model.selected_offset,
     model.documentation,
     Enum.map(model.items, &%{&1 | id: Map.fetch!(ids, &1.id), source: "lsp"})}
  end

  defp normalized_wire_ids(completion) do
    Map.new(completion.filtered, fn %Item{id: {_provider, semantic}} = item ->
      {Item.wire_id(item), Item.wire_id({:bench_provider, semantic})}
    end)
  end

  # The accepted item embeds the stand-in client pid, so the digest keeps its pid-free wire id
  # and the edit it applies.
  defp accepted_digest({:text_edit, %Item{} = item}, ids),
    do: {:text_edit, Map.fetch!(ids, Item.wire_id(item)), item.text_edit}

  defp accepted_digest(accepted, _ids), do: accepted

  defp apply_accepted(_buffer, _completion, nil), do: :ok

  # Places the edit as `CompletionHandling.apply_completion_edit/2` does when the cursor has not
  # moved since the request: LSP UTF-16 columns on the request line, as a half-open byte range.
  defp apply_accepted(buffer, _completion, {:text_edit, %Item{text_edit: edit}}) do
    line_text = buffer_text() |> String.split("\n") |> Enum.at(@edit_line)
    {:ok, {start_col, end_col}} = Item.byte_columns(edit, @edit_line, line_text, :utf16)

    Minga.Buffer.replace_byte_range_if_version(
      buffer,
      Minga.Buffer.version(buffer),
      {@edit_line, start_col},
      end_col - start_col,
      edit.new_text
    )
  end

  defp apply_accepted(buffer, completion, {:insert_text, text}) do
    {line, col} = completion.trigger_position
    Minga.Buffer.apply_edit(buffer, line, col, line, col + 3, text)
  end

  defp measure(fun) do
    {:reductions, r0} = Process.info(self(), :reductions)
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    t1 = System.monotonic_time(:microsecond)
    {:reductions, r1} = Process.info(self(), :reductions)
    {%{us: t1 - t0, reductions: r1 - r0, words: 0}, result}
  end

  # ── Runner ─────────────────────────────────────────────────────────────────

  @spec main([String.t()]) :: :ok
  def main(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [quick: :boolean])

    out_dir =
      case rest do
        [dir | _] -> dir
        [] -> raise ArgumentError, "usage: mix run bench/completion_fields.exs OUT_DIR [--quick]"
      end

    File.mkdir_p!(out_dir)
    counts = if opts[:quick], do: @quick_counts, else: @counts

    rows =
      Enum.flat_map(counts, fn count ->
        response = response(count)
        IO.puts("items=#{count}")
        run_cell(count, response)
      end)

    write_outputs(out_dir, rows, counts)
  end

  defp run_cell(count, response) do
    for _ <- 1..@warmup, do: sample(response)
    max_samples = Map.fetch!(@max_samples, count)
    started = System.monotonic_time(:microsecond)
    collect(count, response, max_samples, started, 0, [], nil)
  end

  defp collect(count, _response, max, _started, max, acc, digest),
    do: finish(count, acc, digest)

  defp collect(count, response, max, started, n, acc, digest) do
    if n > 0 and System.monotonic_time(:microsecond) - started > @budget_us do
      finish(count, acc, digest)
    else
      {stages, sample_digest} = sample(response)
      hash = digest_hash(sample_digest)

      if digest != nil and digest.hash != hash do
        raise "items=#{count}: sample #{n} produced a different digest"
      end

      rows =
        stages
        |> Enum.with_index()
        |> Enum.map(fn {{stage, m}, step} -> {count, n, stage, step, m} end)

      collect(
        count,
        response,
        max,
        started,
        n + 1,
        rows ++ acc,
        %{hash: hash, term: sample_digest}
      )
    end
  end

  defp finish(count, acc, digest) do
    IO.puts("  #{count}: #{acc |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length()} samples")
    [{count, Enum.reverse(acc), digest}]
  end

  defp digest_hash(term) do
    :sha256 |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic])) |> Base.encode16()
  end

  defp write_outputs(out_dir, cells, counts) do
    csv =
      [
        "items,sample,stage,step,us,reductions,words\n"
        | for {_count, rows, _digest} <- cells,
              {count, n, stage, step, m} <- rows do
            "#{count},#{n},#{stage},#{step},#{m.us},#{m.reductions},#{m.words}\n"
          end
      ]

    File.write!(Path.join(out_dir, "samples.csv"), csv)

    summary =
      for {count, rows, digest} <- cells, into: %{} do
        stages =
          rows
          |> Enum.group_by(fn {_c, _n, stage, _step, _m} -> stage end, fn {_, _, _, _, m} -> m end)
          |> Map.new(fn {stage, ms} -> {stage, stats(ms)} end)

        {Integer.to_string(count),
         %{
           digest: digest.hash,
           matched_counts: Enum.map(digest.term.filters, &elem(&1, 1)),
           accepted: inspect(digest.term.accepted),
           stages: stages
         }}
      end

    File.write!(Path.join(out_dir, "summary.json"), JSON.encode!(summary))
    File.write!(Path.join(out_dir, "identity.json"), JSON.encode!(identity(counts)))
    print_summary(summary)
    IO.puts("wrote #{out_dir}")
  end

  defp stats(ms) do
    us = ms |> Enum.map(& &1.us) |> Enum.sort()
    reds = ms |> Enum.map(& &1.reductions) |> Enum.sort()
    words = ms |> Enum.map(& &1.words) |> Enum.sort()

    %{
      n: length(us),
      us_p10: pct(us, 10),
      us_p50: pct(us, 50),
      us_p90: pct(us, 90),
      us_p95: pct(us, 95),
      reductions_p50: pct(reds, 50),
      words_p50: pct(words, 50)
    }
  end

  # Nearest-rank percentile.
  defp pct([], _p), do: 0

  defp pct(sorted, p) do
    rank = max(ceil(p / 100 * length(sorted)), 1)
    Enum.at(sorted, rank - 1)
  end

  defp identity(counts) do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {status, 0} = System.cmd("git", ["status", "--porcelain", "--", "lib"])

    lib_hash =
      ["lib/minga/editing/completion/item.ex", "lib/minga/editing/completion/index.ex"]
      |> Enum.map(&File.read!/1)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16()

    %{
      commit: String.trim(commit),
      lib_dirty: String.split(status, "\n", trim: true),
      completion_sources_sha256: lib_hash,
      counts: counts,
      otp: System.otp_release(),
      elixir: System.version(),
      schedulers: System.schedulers_online(),
      arch: :erlang.system_info(:system_architecture) |> to_string(),
      mix_env: Mix.env(),
      label: System.get_env("MINGA_BENCH_LABEL", "")
    }
  end

  defp print_summary(summary) do
    IO.puts("items  stage      n   p10/p50/p90/p95 us            reductions p50   words p50")

    for count <- summary |> Map.keys() |> Enum.sort_by(&String.to_integer/1),
        {stage, s} <- Enum.sort(summary[count].stages) do
      IO.puts(
        "#{String.pad_leading(count, 6)} #{String.pad_trailing(to_string(stage), 9)} #{String.pad_leading(to_string(s.n), 4)}   " <>
          "#{s.us_p10}/#{s.us_p50}/#{s.us_p90}/#{s.us_p95}   #{s.reductions_p50}   #{s.words_p50}"
      )
    end

    :ok
  end
end

Minga.Bench.CompletionFields.main(System.argv())
