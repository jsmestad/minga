defmodule Minga.RenderModel.Window.ContentDigestTest do
  @moduledoc """
  Invariants for the incremental content digest (#2658, AC3).

  The digest gates the resident-window frame-emit, so the load-bearing
  properties are: (b) the incremental digest always equals a full recompute, and
  the AC3 corollary that a digest changes with overwhelming probability when a
  row's `{row_id, content_hash}` pair changes, with no spurious change on an
  edit-back-to-original.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.RenderModel.Window.ContentDigest
  alias Minga.RenderModel.Window.Row

  # ── Generators ─────────────────────────────────────────────────────────

  # A row is a {row_id, content_hash} pair; row_ids are unique within a window,
  # so we generate distinct ids and let content hashes collide freely.
  defp content_hash_gen, do: integer(0..1_000)

  defp pair_gen(id), do: gen(all(hash <- content_hash_gen()), do: {id, hash})

  defp pair_list_gen(max_count) do
    gen all(
          count <- integer(0..max_count),
          hashes <- list_of(content_hash_gen(), length: count)
        ) do
      Enum.map(Enum.with_index(hashes), fn {hash, id} -> {id, hash} end)
    end
  end

  # ── Full recompute agreement ─────────────────────────────────────────────

  describe "property: incremental digest equals full recompute" do
    property "add-only build equals of_pairs" do
      check all(pairs <- pair_list_gen(60)) do
        incremental =
          Enum.reduce(pairs, ContentDigest.empty(), fn {id, hash}, acc ->
            ContentDigest.add(acc, id, hash)
          end)

        assert incremental == ContentDigest.of_pairs(pairs)
      end
    end

    property "remove is the inverse of add" do
      check all(
              pairs <- pair_list_gen(40),
              extra <- pair_gen(9_999)
            ) do
        {id, hash} = extra
        base = ContentDigest.of_pairs(pairs)

        assert base
               |> ContentDigest.add(id, hash)
               |> ContentDigest.remove(id, hash) == base
      end
    end

    property "update equals remove-then-add" do
      check all(
              pairs <- pair_list_gen(40),
              id <- integer(0..39),
              old_hash <- content_hash_gen(),
              new_hash <- content_hash_gen()
            ) do
        base = ContentDigest.of_pairs(pairs)

        via_update = ContentDigest.update(base, id, old_hash, new_hash)

        via_ops =
          base
          |> ContentDigest.remove(id, old_hash)
          |> ContentDigest.add(id, new_hash)

        assert via_update == via_ops
      end
    end
  end

  # ── Change detection (AC3) ───────────────────────────────────────────────

  describe "property: digest changes iff a row changed" do
    property "changing a row's content hash changes the digest, restoring it undoes the change" do
      check all(
              pairs <- pair_list_gen(40),
              id <- integer(0..39),
              old_hash <- content_hash_gen(),
              new_hash <- content_hash_gen()
            ) do
        base = ContentDigest.of_pairs(pairs)

        changed = ContentDigest.update(base, id, old_hash, new_hash)
        restored = ContentDigest.update(changed, id, new_hash, old_hash)

        # A genuinely different content hash should change the digest (modulo
        # the ~2^-27 phash2 collision rate, which is vanishingly unlikely with
        # our small generator range).
        if old_hash != new_hash do
          assert changed != base
        end

        # No spurious change when the content did not actually change.
        if old_hash == new_hash do
          assert changed == base
        end

        # Editing back to the original content restores the prior digest, so no
        # spurious emit.
        assert restored == base
      end
    end
  end

  # ── AC3 example: insert into the middle of a five-row document ───────────

  describe "insert/delete keep unaffected rows" do
    test "inserting a row only folds in the new row's cell" do
      rows =
        for i <- 0..4 do
          %Row{row_id: i, row_type: :normal, buf_line: i, text: "row #{i}", spans: []}
          |> put_hash()
        end

      digest = ContentDigest.of_rows(rows)

      # A row inserted at index 2 with a fresh id/content only adds one cell; the
      # untouched rows keep their cells, so the delta is exactly that new cell.
      new_row =
        %Row{row_id: 100, row_type: :normal, buf_line: 100, text: "inserted", spans: []}
        |> put_hash()

      with_insert = ContentDigest.add(digest, new_row.row_id, new_row.content_hash)

      expected = ContentDigest.of_rows(List.insert_at(rows, 2, new_row))
      assert with_insert == expected

      # Removing it again returns to the original digest (no dropped/duplicate state).
      assert ContentDigest.remove(with_insert, new_row.row_id, new_row.content_hash) == digest
    end
  end

  defp put_hash(%Row{text: text, spans: spans} = row) do
    %{row | content_hash: Row.compute_hash(text, spans)}
  end
end
