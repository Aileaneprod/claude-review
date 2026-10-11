/**
 * One line of the agents' job log. The summary page renders `run` as
 * "see the run that produced this line", so it must point at a workflow run
 * of this repository, and nothing else.
 */
export interface JobLine {
  run: string;
  commit: string;
  outcome: "success" | "failure";
}

// https://github.com/<owner>/<repo>/<anything>
const RUN_URL = /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_/-]+$/;
const COMMIT_SHA = /^[0-9a-f]{40}$/;

export function jobLine(input: { run: string; commit: string; outcome: string }): JobLine {
  if (!RUN_URL.test(input.run)) {
    throw new TypeError(`run must be a workflow run URL, got ${input.run}`);
  }
  if (!COMMIT_SHA.test(input.commit)) {
    throw new TypeError(`commit must be a full 40-character SHA, got ${input.commit}`);
  }
  if (input.outcome !== "success" && input.outcome !== "failure") {
    throw new TypeError(`outcome must be success or failure, got ${input.outcome}`);
  }
  return { run: input.run, commit: input.commit, outcome: input.outcome };
}
