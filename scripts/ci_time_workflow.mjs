// Workflow classification and timeout contract for the hosted CI time report.
// Keep old workflow job names until their retained runs are no longer reported.
export const blockingJobs = Object.freeze({
  pull_request: new Set(['repository-hygiene', 'lint', 'scope', 'swift-scope', 'build-and-test',
    'ios-portability', 'build-ui-products', 'scoped-ui-tests', 'interruption-controls',
    'ui-test-gate', 'ui-tests', 'interruption', 'gate']),
  push: new Set(['repository-hygiene', 'lint', 'build-and-test', 'ios-portability']),
});
export const nonBlockingJobs = new Set(['alert', 'meeting-review-comparison']);

export const productSteps = new Set([
  'Repository, evidence, and CI policy contracts', 'Release performance ledger rules', 'Legacy tooling contracts',
  'Select the Swift test scope', 'Select the iOS lane',
  'Current-SDK build and selected test suite', 'Compile transport-neutral iOS 26 surface',
  'Strict SwiftLint 0.65.0 from checksum-pinned official archive', 'Validate the selector catalog',
  'Select UI evidence', 'Verify interruption safety at the shared callback',
  'Build the UI host and runner once', 'Fit the selection to what remains of the job',
  'Run functional UI evidence', 'Classify functional evidence and hosted runtime drift',
  'Require every lane the selection asked for', 'Fail the lane when its evidence is not complete',
]);
const infrastructureStep = /^(Set up job|Complete job|Post |Run actions\/|Verify fixed|Install checksum|Identify compatible|Restore|Verify cached|Unpack|Archive|Publish|Preserve|Upload|Collect|Resolve the last|Explain the selection|Check Swift cache|Save successful|Record |Create content-free)/;

// A name matching neither policy is unknown; callers must not infer an outcome.
export function classifyStep(name) {
  if (typeof name !== 'string') return null;
  const product = productSteps.has(name), infrastructure = infrastructureStep.test(name);
  return product === infrastructure ? null : product ? 'product' : 'infrastructure';
}

// Restrict discovery to top-level jobs; a missing timeout must not hide a job.
function workflowJobs(text) {
  if (typeof text !== 'string') throw new TypeError('Expected workflow text');
  const jobs = new Map();
  let inJobs = false, job = null;
  for (const line of text.split(/\r\n|\r|\n/)) {
    if (!inJobs) {
      if (/^jobs:\s*(?:#.*)?$/.test(line)) inJobs = true;
      continue;
    }
    if (/^[^\s#]/.test(line)) break;
    const declaration = /^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$/.exec(line);
    if (declaration) {
      job = declaration[1];
      if (jobs.has(job)) throw new Error('Duplicate workflow job');
      jobs.set(job, []);
    } else if (/^  [^\s#]/.test(line)) {
      throw new Error('Unsupported workflow job syntax');
    } else if (job) jobs.get(job).push(line);
  }
  if (!inJobs) throw new Error('Missing workflow jobs');
  return jobs;
}

export function workflowJobNames(text) { return [...workflowJobs(text).keys()]; }

// Parse job-level timeout-minutes only. The final fallback is the PR ceiling.
export function declaredTimeouts(workflowTexts) {
  const timeouts = {};
  for (const text of workflowTexts) {
    for (const [job, lines] of workflowJobs(text)) {
      for (const line of lines) {
        const timeout = /^    timeout-minutes: (?:\$\{\{.*\|\| )?(\d+)(?: \}\})?\s*$/.exec(line);
        if (timeout) timeouts[job] = Number(timeout[1]);
      }
    }
  }
  return timeouts;
}
