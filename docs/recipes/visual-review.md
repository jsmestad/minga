# Run the visual review

A pull request that changes how a storyboard scenario looks gets a visual review before it is marked ready. The review is done by agents, not people, and it never blocks a merge: the hard gates decide that (see [Renders and baselines](../design/storyboard.md#renders-and-baselines)). It exists to catch what measurements miss, a surface that passes the layout audit and still reads badly, or that tells a different story on each frontend.

CI does not run agents, so the Minga ticket runner runs this procedure as a required step for every UI pull request, after CI has rendered the storyboard. A later change may move it into a workflow; the inputs, outputs and records stay the same.

## When it runs

Run it when the **Storyboard renders** job of the pull request's latest CI run lists changed scenarios in its summary, or when the pull request promotes a scenario's first baselines. When nothing changed, there is nothing to review; say so on the pull request and skip the rest.

## 1. Gather the inputs

```bash
python3 design/tools/storyboard/review.py inputs --run <ci-run-id> --out /tmp/visual-review
```

This downloads the run's storyboard artifacts and writes one folder per changed scenario: every frame on both frontends in every theme and size as a PNG (TUI frames are drawn from their text grid and colours), the scenario's boards rendered with headless Chrome, and `review.json`, which lists them. Pass `--all` instead of relying on the diff when the pull request promotes first baselines. The number of scenarios it prints is the review's cost: reviewers and the critic only ever see changed scenarios.

## 2. Two independent reviewers

Start two reviewer agents in parallel, each in a fresh context, with no access to each other's output. Give each:

- `review.json` and the scenario folders;
- [the rubric](../design/visual_rubric.md) and [anatomy.md](../design/anatomy.md);
- the instruction to return one JSON object per scenario: `{"scenario", "reviewer", "verdict": "pass" | "concern", "notes"}`, naming frontend, theme, size, part and rubric question in the notes.

The reviewers check structure against the board and polish against anatomy, and nothing else. They do not see the pull request's discussion, so their verdicts are not anchored on the implementer's.

## 3. The polish critic, at most three rounds

Then start a critic agent, also fresh, without the reviewers' verdicts. Give it the same frames, anatomy.md, the rubric's quality bar (the surfaces and Human Interface Guidelines sections it names), and ask for `{"scenario", "part", "issue", "suggested"}` items.

For each item, the implementer either fixes it, re-renders and re-runs the hard gates, or declines it with a reason. Run the critic again on the new renders. Stop after a round with no items, after a round in which every item was declined (there are no new renders to critique), or after round three, whichever comes first. A rerun after a later push that leaves nothing open replaces the pull request's follow-up section with "Nothing open".

## 4. Record the verdicts

Write the review record (the format is at the top of `review.py`), then post it and file what is left:

```bash
python3 design/tools/storyboard/review.py comment --pr <number> --record record.json --review /tmp/visual-review/review.json
python3 design/tools/storyboard/review.py followups --pr <number> --record record.json --comment <comment-url> --review /tmp/visual-review/review.json
```

Both commands refuse a record that misses a changed scenario or one of the two verdicts, or that has more than three critic rounds. Running the review again after a later push replaces the pull request's comment and its section of the follow-ups issue instead of adding new ones. When no macOS input changed, CI renders no macOS frames; `review.json` says so, and the reviewers judge the TUI frames alone.

`comment` posts one "Visual review" comment with both reviewers' verdicts side by side, the critic's rounds and what happened to each item, and the number of changed scenarios reviewed. `followups` appends every concern, every disagreement between the reviewers, and every critic item that is open or declined to the visual follow-ups issue ([#4071](https://github.com/jsmestad/minga/issues/4071)), each entry naming the scenario, the pull request and a link to the notes.

## 5. Merge on the hard gates

Visual review is done when its comment is posted and its follow-ups are filed. The pull request merges when the hard gates pass, whatever the reviewers or the critic said.
