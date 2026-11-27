defmodule Minga.Buffer.KeptReviewSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.KeptReview.Source
  alias Minga.Buffer.Provenance

  @task {:minga, "review-task"}

  test "couples each adjacent replacement to its own complete preimage" do
    {step, provenance} = Provenance.open_group(Provenance.new(3), @task, {"review-task", 1})
    edits = [{0, "x", "AA"}, {1, "y", "B"}]

    for mode <- [:each, :batch] do
      edited = Provenance.edit_all(provenance, step, edits, mode)
      sources = Provenance.keep_sources(edited, [step])

      assert [
               %Source{kind: :replace, point: 0, old: "x", new: "AA"},
               %Source{kind: :replace, point: 2, old: "y", new: "B"}
             ] = Source.project(sources, "AABz")
    end
  end

  test "a later user overwrite cannot turn part of a replacement into proof of the whole" do
    {step, provenance} = Provenance.open_group(Provenance.new(3), @task, {"review-task", 1})
    provenance = Provenance.edit(provenance, step, 1, "x", "ABC")
    {user, provenance} = Provenance.open_group(provenance, :you, nil)
    provenance = Provenance.edit(provenance, user, 2, "B", "b")

    assert [] = Source.project(Provenance.keep_sources(provenance, [step]), "aAbCc")
  end

  test "independent fragments of a pure insertion keep their original source offsets" do
    {step, provenance} = Provenance.open_group(Provenance.new(2), @task, {"review-task", 1})
    provenance = Provenance.edit(provenance, step, 1, "", "XYZ")
    {user, provenance} = Provenance.open_group(provenance, :you, nil)
    provenance = Provenance.edit(provenance, user, 2, "Y", "!")

    assert [
             %Source{kind: :insert, id: id, offset: 0, point: 1, old: "", new: "X"},
             %Source{kind: :insert, id: id, offset: 2, point: 3, old: "", new: "Z"}
           ] = Source.project(Provenance.keep_sources(provenance, [step]), "aX!Zb")
  end

  test "different direct deletions with indistinguishable ordering are not invented as one splice" do
    {first, provenance} = Provenance.open_group(Provenance.new(4), @task, {"review-task", 1})
    provenance = Provenance.edit(provenance, first, 1, "x", "")
    {second, provenance} = Provenance.open_group(provenance, @task, {"review-task", 2})
    provenance = Provenance.edit(provenance, second, 1, "y", "")

    assert [] = Source.project(Provenance.keep_sources(provenance, [first, second]), "ab")
  end
end
