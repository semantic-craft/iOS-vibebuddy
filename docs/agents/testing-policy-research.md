# Which tests to keep when agents write the code

Research note, 2026-09-25. It backs the Verification rule in `AGENTS.md` ("a small number of fast tests for critical pure logic or a reproduced regression") with outside sources and turns it into a keep/delete rubric. The rubric was first applied in the pruning PR that added this file. All quotes were checked against the primary page on 2026-09-25.

## What the sources say

- **Tests that restate the code cost more than they catch.** A change-detector test "breaks in response to any change to the production code" and finds no defects. Google's advice is that these tests "should be re-written or deleted." Alex Eagle, *Change-Detector Tests Considered Harmful*, Google Testing Blog, 2015. <https://testing.googleblog.com/2015/01/testing-on-toilet-change-detector-tests.html>
- **Test behaviour, not implementation.** If the user-facing behaviour is unchanged, the test itself "typically shouldn't need to change." Andrew Trenk, *Test Behavior, Not Implementation*, Google Testing Blog, 2013. <https://testing.googleblog.com/2013/08/testing-on-toilet-test-behavior-not.html>
- **Chasing coverage produces low-value tests.** Near 100% you end up testing code with no logic, and those tests slow refactors down. Kent C. Dodds, *Write tests. Not too many. Mostly integration.*, 2019. <https://kentcdodds.com/blog/write-tests>
- **Overlapping coverage is itself a cost.** Justin Searls asks teams to track "the amount of redundant coverage across all of our tests." Isolated tests still need a thin integration test to show the parts are wired together. *Please don't mock me*, Test Double, 2018. <https://testdouble.com/insights/please-dont-mock-me>. See also DHH on test-induced design damage (2014): <https://dhh.dk/2014/test-induced-design-damage.html>
- **Agent-written tests often assert nothing.** In 86,156 test patches from agent-authored PRs, including Claude Code's, 80.2% had weak or no oracle. Banik et al., *All Smoke, No Alarm*, arXiv, 2026. <https://arxiv.org/abs/2606.18168>
- **Test-first prompting did not raise agent test quality.** Böckeler found "no clearly discernable difference" in mutation scores between TDD and non-TDD agent runs. TDD cost at least 3× the tokens, and some tests checked the implementation's output against itself. She judges regression tests with mutation testing instead. *TDD inside the agent loop*, martinfowler.com, 2026. <https://martinfowler.com/articles/exploring-gen-ai/tdd-in-the-agent-loop.html>
- **Judge a suite by fault detection, not count.** Thoughtworks put mutation testing in Trial so teams catch "perpetually green" AI-generated tests. Technology Radar, Apr 2026. <https://www.thoughtworks.com/radar/techniques/mutation-testing>

## Counter-arguments

- **The agent needs a check it can run.** "Give Claude a check it can run: tests, a build, a screenshot." Anthropic, *Best practices for Claude Code*. <https://code.claude.com/docs/en/best-practices>
- **Tests are no longer optional.** "Automated tests are no longer optional when working with coding agents." A test that already passes proves nothing, so Willison has agents watch it fail first. Simon Willison, *Agentic Engineering Patterns*, 2026. <https://simonwillison.net/guides/agentic-engineering-patterns/first-run-the-tests/>
- **Agents must not weaken tests to get green.** Kent Beck treats a genie "disabling or deleting tests" as a warning sign (*Augmented Coding: Beyond the Vibes*, 2025, <https://newsletter.kentbeck.com/p/augmented-coding-beyond-the-vibes>). Anthropic's prompting guide says "Tests are there to verify correctness, not to define the solution." (<https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices>)

## Conclusion for this repo

Keep a lean set of behaviour tests and regression tests as the agent's gate, and never edit one just to make it pass. Delete change-detectors, copy and constant restatements, and tests that duplicate each other; agents produce these in bulk and they cost upkeep without catching bugs. End-to-end acceptance (`AGENTS.md` § Verification) stays the main proof. Unit tests only pin rules and past bugs.

## Rubric

Judge each `@Test` / `func test…`. A parameterised test counts as one.

**KEEP** if any of these holds:

- **K1 Regression guard.** The test names or documents a reproduced bug or ticket (WR-, AI-, PERF-, T-, RV-, ADR-, #PR, "the bug"), or it was added in a `fix(...)` commit for a real failure. To check, run `git log --format='%h %s' -S'<func>' -- <file> | tail -1`. When one fix added several tests, keep the ones that reproduce the bug.
- **K2 Security or permission boundary.** Approve/deny/ask routing, allow rules, tokens, auth and pairing, argv secrecy, "never auto-approve", fail-closed paths, and every route's "no token → 401" check.
- **K3 Wire contract.** Decoding captured or realistic payloads: hook JSON, app-server and ACP messages, rollout lines, APNs, the Mac↔phone snapshot, files on disk. Also forward and backward compatibility of wire raw values.
- **K4 Decision logic other code relies on.** State reduction, routing, dedup, held decisions, fan-out, quota maths and recovery. Pin the rule, not every input.
- **K5 Installer and on-disk changes.** Idempotency, uninstall that restores the original, never clobbering user config.
- **K6 Races, ordering and cancellation.**

**DELETE** only for one of these reasons, and name it:

- **D1 Restates the code.** A constant equals its literal, a synthesized `Codable` round trip, a getter or memberwise init, a switch table retyped as expectations, "every case has a non-empty name".
- **D2 Copy or layout.** Exact user-facing strings, localisation text, colours, sizes, animation offsets. Keep one when it is a wire key or guards a copy bug (K1).
- **D3 Edge-case matrix.** A sibling input for a rule that a kept test already pins.
- **D4 Duplicate.** Another test, in this package or another (Kit / Mac / iOS), covers the same behaviour. Keep the one closest to the code.
- **D5 Dead feature.** Also remove the production code if the test was its only caller.
- **D6 Smoke test.** "Doesn't crash" or "is not nil" when a richer test covers the path.
- **D7 Tests a test double** instead of production code.

Tie-breakers: when unsure, keep. Env-gated live tests cost nothing in a normal run, so keep them unless D5 applies. A deletion must leave every K1–K6 behaviour covered. After deleting, remove helpers left unused. New tests must meet the same bar: a new test should fit K1–K6.
