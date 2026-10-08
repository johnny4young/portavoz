#!/usr/bin/env python3
"""Score bounded, content-free dictation evidence; never qualify a population."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import re
import sys

import dictation_corpus as corpus
from dictation_model_receipt import number, validate_score
from materialize_dictation_corpus import fingerprint, publish_json

STAGES = ('raw', 'postRule')
STATUSES = ('completed', 'cancelled', 'refused', 'failed', 'timed-out')
DELIVERY = ('not-attempted', 'refused', 'dispatched-unverified', 'verified', 'failed')
PHASES = ('ready', 'speechOnset', 'speechEnd', 'firstRenderedPartial', 'stop',
          'prepared', 'dispatch', 'receiver', 'cancel')
STRATA = ('quiet-es', 'quiet-en', 'quiet-mixed', 'snr10', 'other-speech', 'no-speech')
EDITS = ('Substitutions', 'Deletions', 'Insertions')
SAFETY = ('wrongTarget', 'wrongSelection', 'wrongText', 'duplicateInsertion',
          'nonSpeechInsertion', 'ineligibleDispatch', 'dispatchAfterCancel')
LIMIT = 10000
METRIC_REGISTRY = {
    'version': 1,
    'precision': {'stages': list(STAGES), 'units': ['word', 'character'],
                  'numerator': 'substitutions-plus-deletions-plus-insertions',
                  'denominator': 'declared-reference-count-for-planned-speech',
                  'estimator': 'micro-plus-word-speaker-macro',
                  'missing': 'complete-rate-null-and-available-case-rate-separate'},
    'latency': {'unit': 'monotonic-ms', 'estimator': 'completed-success-conditional-nearest-rank',
                'denominator': 'frozen-planned-eligible-attempts-per-temperature',
                'missing': 'count-missing-or-unsuccessful-never-zero'},
    'delivery': {'unit': 'fraction', 'numerator': 'declared-matching-receiver-proofs',
                 'denominator': 'frozen-delivery-eligible-plan-including-missing',
                 'missing': 'retain-in-denominator-and-separate-outcome'},
    'nonSpeech': {'unit': 'incidence-and-lexical-words-per-minute', 'stage': 'postRule',
                  'denominator': 'planned-no-speech-and-scored-fed-frame-exposure',
                  'missing': 'complete-incidence-null-and-observed-incidence-separate'},
    'interval': None, 'candidateThreshold': None,
    'qualification': 'never-population-qualified',
}


def schema(value, keys):
    corpus.exact_keys(value, keys, 'benchmark schema mismatch')


def require(condition, reason):
    corpus.require(condition, reason)


def inventory(value, maximum=LIMIT):
    require(type(value) is list and len(value) <= maximum, 'invalid benchmark inventory')


def count(value, maximum=1000000):
    require(corpus.integer(value, 0, maximum), 'invalid benchmark count')


def identity(value):
    require(corpus.identifier(value), 'invalid opaque benchmark identity')


def digest(value):
    require(corpus.digest(value), 'invalid benchmark digest')


def configuration(value):
    schema(value, 'sourceCommit treeClean binaryDigest dependencyDigest modelDigests runtimeDigest '
           'normalizerDigest protocolDigest hostDigest dictionaryDigest profileID networkPolicy '
           'clockCalibrationDigest clockUnit')
    require(type(value['sourceCommit']) is str and re.fullmatch('[0-9a-f]{40}', value['sourceCommit']),
            'invalid source commit')
    require(type(value['treeClean']) is bool and value['clockUnit'] == 'monotonic-ms'
            and value['networkPolicy'] == 'local-only', 'unsupported benchmark configuration')
    for key in ('binaryDigest', 'dependencyDigest', 'runtimeDigest', 'normalizerDigest',
                'protocolDigest', 'hostDigest', 'dictionaryDigest', 'clockCalibrationDigest'):
        digest(value[key])
    inventory(value['modelDigests'], 16)
    for item in value['modelDigests']:
        digest(item)
    require(value['modelDigests'] and len(set(value['modelDigests'])) == len(value['modelDigests']),
            'invalid model inventory')
    identity(value['profileID'])


def manifest(value, evidence):
    schema(value, 'datasetID provenance licenseReviewID consentPolicyID cases')
    identity(value['datasetID'])
    require(value['provenance'] in ('synthetic-fixture', 'consented-adult-declared')
            and (evidence == 'synthetic-fixture') == (value['provenance'] == 'synthetic-fixture'),
            'inconsistent dataset provenance')
    identity(value['licenseReviewID'])
    if evidence == 'synthetic-fixture':
        require(value['consentPolicyID'] is None, 'synthetic fixture must not claim human consent')
    else:
        identity(value['consentPolicyID'])
    inventory(value['cases'])
    require(value['cases'], 'empty benchmark dataset')
    cases, splits = {}, {}
    for case in value['cases']:
        schema(case, 'caseID speakerClusterID familyID sessionID split stratum audioDigest '
               'referenceDigest referenceWords referenceCharacters sampleRate frames speechExpected')
        identity(case['caseID'])
        require(case['caseID'] not in cases, 'duplicate dataset case')
        cases[case['caseID']] = case
        require(case['split'] in ('tuning', 'development', 'holdout')
                and case['stratum'] in STRATA and type(case['speechExpected']) is bool,
                'invalid dataset stratum')
        for key in ('speakerClusterID', 'familyID', 'sessionID', 'audioDigest', 'referenceDigest'):
            digest(case[key])
            if key != 'referenceDigest' or case['speechExpected']:
                previous = splits.setdefault((key, case[key]), case['split'])
                require(previous == case['split'], 'dataset identity leaks across splits')
        for key in ('referenceWords', 'referenceCharacters', 'frames', 'sampleRate'):
            count(case[key], 19200000 if key == 'frames' else 1000000)
        require(case['sampleRate'] == 16000 and 0 < case['frames'] <= 19200000,
                'unsupported dataset audio accounting')
        require(case['referenceCharacters'] >= case['referenceWords']
                and case['speechExpected'] == (case['referenceWords'] > 0)
                and case['speechExpected'] == (case['referenceCharacters'] > 0)
                and case['speechExpected'] == (case['stratum'] != 'no-speech'),
                'inconsistent speech reference')
    return cases


def run_plan(value, config, dataset, cases):
    schema(value, 'generationID configurationDigest datasetDigest metricRegistryDigest seed attempts')
    identity(value['generationID'])
    require(value['configurationDigest'] == fingerprint(config)
            and value['datasetDigest'] == fingerprint(dataset)
            and value['metricRegistryDigest'] == fingerprint(METRIC_REGISTRY), 'run-plan identity mismatch')
    count(value['seed'], 2**32 - 1)
    inventory(value['attempts'])
    require(value['attempts'], 'empty run plan')
    planned, keys = {}, set()
    for item in value['attempts']:
        schema(item, 'attemptID caseID repetition conditionID temperature deliveryEligible targetID selectionID')
        for key in ('attemptID', 'caseID', 'conditionID', 'targetID', 'selectionID'):
            identity(item[key])
        require(item['attemptID'] not in planned and item['caseID'] in cases, 'invalid planned case')
        require(corpus.integer(item['repetition'], 1, 100)
                and item['temperature'] in ('warm', 'process-cold')
                and type(item['deliveryEligible']) is bool, 'invalid planned condition')
        # A correct no-speech outcome inserts nothing; it cannot be a delivery denominator.
        require(not item['deliveryEligible'] or cases[item['caseID']]['speechExpected'],
                'no-speech attempt cannot be delivery eligible')
        key = (item['caseID'], item['repetition'], item['conditionID'])
        require(key not in keys, 'duplicate planned repetition')
        keys.add(key)
        planned[item['attemptID']] = item
    return planned


def edits(score, unit):
    return sum(score[unit + name] for name in EDITS)


def stage_score(value, case):
    if value is None:
        return
    schema(value, 'wordSubstitutions wordDeletions wordInsertions hypothesisWords '
           'characterSubstitutions characterDeletions characterInsertions hypothesisCharacters')
    for item in value.values():
        count(item)
    rates = {}
    for unit, reference_key, hypothesis_key in (
            ('word', 'referenceWords', 'hypothesisWords'),
            ('character', 'referenceCharacters', 'hypothesisCharacters')):
        ref, hypothesis, total = case[reference_key], value[hypothesis_key], edits(value, unit)
        sub, delete, insert = (value[unit + name] for name in EDITS)
        require(sub + delete <= ref and hypothesis == ref - delete + insert
                and total <= max(ref, hypothesis), 'impossible edit accounting')
        rates[unit + 'ErrorRate'] = total / ref if ref else int(hypothesis > 0)
    require((value['hypothesisWords'] == 0) == (value['hypothesisCharacters'] == 0)
            and value['hypothesisCharacters'] >= value['hypothesisWords'], 'inconsistent hypothesis counts')
    # Reuse the existing producer's bounded plausibility checks; its legacy
    # empty-reference sentinel is NEVER aggregated as WER/CER below.
    validate_score(dict(**rates, referenceWords=case['referenceWords'],
                        hypothesisWords=value['hypothesisWords'], exactReferenceMatch=False,
                        legacyCleanupChangedText=False))


def phases(value):
    schema(value, ' '.join(PHASES))
    for item in value.values():
        require(item is None or number(item, 3600000), 'invalid monotonic millisecond offset')
    for before, after in (('speechOnset', 'speechEnd'), ('speechOnset', 'firstRenderedPartial'),
                          ('stop', 'prepared'), ('speechEnd', 'prepared'),
                          ('prepared', 'dispatch'), ('dispatch', 'receiver')):
        if value[after] is not None and before in ('stop', 'prepared', 'dispatch'):
            require(value[before] is not None, 'missing causal phase')
        if value[before] is not None and value[after] is not None:
            require(value[before] <= value[after], 'reversed causal phases')


def receiver(value, attempt, item, generation):
    if value is None:
        require(attempt['deliveryOutcome'] != 'verified' and attempt['phases']['receiver'] is None,
                'receiver evidence missing')
        return
    schema(value, 'generationID attemptID targetID selectionID textDigest insertionCount acknowledgementMs')
    require(value['generationID'] == generation and value['attemptID'] == item['attemptID'],
            'receiver generation mismatch')
    identity(value['targetID'])
    identity(value['selectionID'])
    digest(value['textDigest'])
    count(value['insertionCount'], 100)
    require(value['insertionCount'] > 0 and number(value['acknowledgementMs'], 3600000)
            and value['acknowledgementMs'] == attempt['phases']['receiver']
            and attempt['phases']['dispatch'] is not None, 'invalid receiver acknowledgement')
    if attempt['deliveryOutcome'] == 'verified':
        require(value['targetID'] == item['targetID'] and value['selectionID'] == item['selectionID']
                and value['textDigest'] == attempt['preparedTextDigest'] and value['insertionCount'] == 1,
                'verified delivery lacks intended-target exact-text evidence')


def validate(document):
    schema(document, 'kind schemaVersion evidenceClass configuration dataset plan attempts')
    require(document['kind'] == 'dictation-benchmark-input' and type(document['schemaVersion']) is int
            and document['schemaVersion'] == 1 and document['evidenceClass'] in
            ('synthetic-fixture', 'declared-observation'), 'unsupported benchmark format')
    config, dataset, plan = (document[key] for key in ('configuration', 'dataset', 'plan'))
    configuration(config)
    cases = manifest(dataset, document['evidenceClass'])
    planned = run_plan(plan, config, dataset, cases)
    inventory(document['attempts'])
    observed = {}
    plan_digest = fingerprint(plan)
    for attempt in document['attempts']:
        schema(attempt, 'attemptID planDigest status failureReason fedFrames scores phases '
               'deliveryOutcome preparedTextDigest receiverProof')
        key = attempt['attemptID']
        require(type(key) is str and key in planned and key not in observed, 'unexpected or repeated attempt')
        require(attempt['planDigest'] == plan_digest, 'attempt run-plan mismatch')
        item = planned[key]
        case = cases[item['caseID']]
        require(attempt['status'] in STATUSES and attempt['deliveryOutcome'] in DELIVERY,
                'invalid terminal outcome')
        reasons = {'completed': (None,), 'cancelled': ('user-cancelled',), 'timed-out': ('timeout',),
                   'refused': ('capture', 'model', 'delivery', 'safety'),
                   'failed': ('capture', 'model', 'delivery', 'safety')}
        require(attempt['failureReason'] in reasons[attempt['status']], 'terminal failure reason mismatch')
        count(attempt['fedFrames'], case['frames'])
        require(attempt['status'] != 'completed' or attempt['fedFrames'] == case['frames'],
                'completed attempt lacks planned input frames')
        schema(attempt['scores'], ' '.join(STAGES))
        for score in attempt['scores'].values():
            stage_score(score, case)
        phases(attempt['phases'])
        require(attempt['status'] != 'cancelled' or attempt['phases']['cancel'] is not None,
                'cancelled attempt lacks cancel phase')
        if attempt['preparedTextDigest'] is not None:
            digest(attempt['preparedTextDigest'])
            require(attempt['phases']['prepared'] is not None, 'prepared text lacks phase evidence')
        if attempt['phases']['dispatch'] is not None:
            require(attempt['preparedTextDigest'] is not None and attempt['deliveryOutcome'] in
                    ('verified', 'dispatched-unverified', 'failed'), 'dispatch evidence mismatch')
        if attempt['deliveryOutcome'] in ('verified', 'dispatched-unverified'):
            require(attempt['phases']['dispatch'] is not None, 'delivery outcome lacks dispatch')
        receiver(attempt['receiverProof'], attempt, item, plan['generationID'])
        observed[key] = attempt
    return cases, planned, observed, plan_digest


def ratio(numerator, denominator):
    return numerator / denominator if denominator else None


def precision(items, observed, cases, stage):
    speech = [item for item in items if cases[item['caseID']]['speechExpected']]
    scored = [(cases[item['caseID']], observed[item['attemptID']]['scores'][stage])
              for item in speech if item['attemptID'] in observed
              and observed[item['attemptID']]['scores'][stage] is not None]
    result = {'plannedSpeechAttempts': len(speech), 'scoredAttempts': len(scored),
              'missingScores': len(speech) - len(scored)}
    for unit, refkey in (('word', 'referenceWords'), ('character', 'referenceCharacters')):
        errors = sum(edits(score, unit) for _, score in scored)
        denominator = sum(case[refkey] for case, _ in scored)
        result[unit] = {'edits': errors, 'scoredReferenceCount': denominator,
                        'plannedReferenceCount': sum(cases[item['caseID']][refkey] for item in speech),
                        'observedErrorRate': ratio(errors, denominator),
                        'completeErrorRate': ratio(errors, denominator) if len(scored) == len(speech) else None}
    # Speaker-macro is descriptive, with the same missing-data boundary.
    speakers = defaultdict(lambda: [0, 0])
    for case, score in scored:
        pair = speakers[case['speakerClusterID']]
        pair[0] += edits(score, 'word')
        pair[1] += case['referenceWords']
    result['scoredSpeakerClusters'] = len(speakers)
    result['observedSpeakerMacroWER'] = (sum(e / n for e, n in speakers.values()) / len(speakers)
                                         if speakers else None)
    result['missingReason'] = 'missing-stage-scores' if result['missingScores'] else None
    return result


def quantiles(values):
    values = sorted(values)
    return {key: values[math.ceil(len(values) * p) - 1] if values else None
            for key, p in (('p50', .5), ('p95', .95))}


def summarize(document, input_digest):
    digest(input_digest)
    cases, planned, observed, plan_digest = validate(document)
    plan = document['plan']
    groups = defaultdict(list)
    for item in planned.values():
        case = cases[item['caseID']]
        groups[(case['split'], case['stratum'])].append(item)
    precision_rows = [{'split': split, 'stratum': stratum,
                       'stages': {stage: precision(items, observed, cases, stage) for stage in STAGES}}
                      for (split, stratum), items in sorted(groups.items())]
    latency = []
    for temperature in ('warm', 'process-cold'):
        for metric, start, end in (('request-to-ready', None, 'ready'),
                                   ('onset-to-rendered-partial', 'speechOnset', 'firstRenderedPartial'),
                                   ('stop-to-prepared', 'stop', 'prepared'),
                                   ('stop-to-observed-edit', 'stop', 'receiver')):
            items = [item for item in planned.values() if item['temperature'] == temperature
                     and (metric != 'onset-to-rendered-partial' or cases[item['caseID']]['speechExpected'])
                     and (metric != 'stop-to-observed-edit' or item['deliveryEligible'])]
            values = []
            for item in items:
                attempt = observed.get(item['attemptID'])
                if attempt is None or attempt['status'] != 'completed':
                    continue
                if metric == 'stop-to-observed-edit' and attempt['deliveryOutcome'] != 'verified':
                    continue
                points = attempt['phases']
                if points[end] is not None and (start is None or points[start] is not None):
                    values.append(points[end] - (points[start] if start else 0))
            latency.append({'metric': metric, 'temperature': temperature, 'unit': 'ms',
                            'eligiblePlanned': len(items), 'measuredCompleted': len(values),
                            'missingOrUnsuccessful': len(items) - len(values),
                            'missingReason': 'missing-phase-or-unsuccessful-attempt'
                            if len(items) > len(values) else None,
                            'estimator': 'success-conditional-nearest-rank', **quantiles(values)})
    eligible = [item for item in planned.values() if item['deliveryEligible']]
    delivery_counts = Counter(observed[item['attemptID']]['deliveryOutcome']
                              if item['attemptID'] in observed else 'missing' for item in eligible)
    safety = Counter(dict.fromkeys(SAFETY, 0))
    for key, attempt in observed.items():
        item = planned[key]
        proof, points = attempt['receiverProof'], attempt['phases']
        if proof:
            safety['wrongTarget'] += proof['targetID'] != item['targetID']
            safety['wrongSelection'] += proof['selectionID'] != item['selectionID']
            safety['wrongText'] += proof['textDigest'] != attempt['preparedTextDigest']
            safety['duplicateInsertion'] += proof['insertionCount'] > 1
            safety['nonSpeechInsertion'] += not cases[item['caseID']]['speechExpected']
        safety['ineligibleDispatch'] += points['dispatch'] is not None and not item['deliveryEligible']
        safety['dispatchAfterCancel'] += (points['cancel'] is not None and points['dispatch'] is not None
                                          and points['cancel'] < points['dispatch'])
    silence = [item for item in planned.values() if not cases[item['caseID']]['speechExpected']]
    lexical, exposure_frames, words, known = 0, 0, 0, 0
    for item in silence:
        attempt = observed.get(item['attemptID'])
        if attempt is not None and attempt['scores']['postRule'] is not None:
            n = attempt['scores']['postRule']['hypothesisWords']
            lexical += n > 0
            words += n
            known += 1
            exposure_frames += attempt['fedFrames']
    statuses = Counter(a['status'] for a in observed.values())
    return {'kind': 'dictation-benchmark-report', 'schemaVersion': 1, 'inputDigest': input_digest,
            # run_plan/validate already bound these digests to the exact admitted objects.
            'configurationDigest': plan['configurationDigest'],
            'datasetDigest': plan['datasetDigest'], 'planDigest': plan_digest,
            'sourceCommit': document['configuration']['sourceCommit'],
            'binaryDigest': document['configuration']['binaryDigest'],
            'normalizerDigest': document['configuration']['normalizerDigest'],
            'modelDigests': document['configuration']['modelDigests'],
            'metricRegistryDigest': plan['metricRegistryDigest'],
            'evidenceClass': document['evidenceClass'], 'audioBytesVerified': False,
            'consentVerified': False, 'populationQualified': False,
            'counts': {'planned': len(planned), 'observed': len(observed), 'missing': len(planned) - len(observed),
                       'datasetCases': len(cases),
                       'plannedCases': len({item['caseID'] for item in planned.values()}),
                       'unselectedCases': len(set(cases) - {item['caseID'] for item in planned.values()}),
                       'plannedSpeakerClusters': len({cases[item['caseID']]['speakerClusterID']
                                                      for item in planned.values() if cases[item['caseID']]['speechExpected']}),
                       'plannedFamilyClusters': len({cases[item['caseID']]['familyID']
                                                     for item in planned.values()}),
                       'terminal': {status: statuses[status] for status in STATUSES}},
            'precision': precision_rows, 'latency': latency,
            'delivery': {'eligiblePlanned': len(eligible),
                         'outcomes': {key: delivery_counts[key] for key in (*DELIVERY, 'missing')},
                         'verifiedFractionOfAllPlanned': ratio(delivery_counts['verified'], len(eligible))},
            'nonSpeech': {'planned': len(silence), 'scored': known, 'missing': len(silence) - known,
                          'lexicalProposals': lexical, 'observedIncidence': ratio(lexical, known),
                          'completeIncidence': ratio(lexical, known) if known == len(silence) else None,
                          'scoredExposureMs': exposure_frames / 16,
                          'lexicalWordsPerMinute': ratio(words, exposure_frames / (16000 * 60))},
            'safetyCounterexamples': dict(safety),
            'gate': 'fail' if any(safety.values()) else 'inconclusive' if observed else 'not-run',
            'uncertainty': {'interval': None, 'method': 'not-estimated',
                            'reason': 'independent-population-evidence-not-admitted'},
            'limitations': ['asserted-inputs-not-producer-attestation', 'consent-record-review-required',
                            'audio-reference-bytes-not-inspected', 'no-semantic-or-resource-qualification',
                            'no-population-confidence-bound', 'no-acceptance-thresholds-adopted']}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New owner-only JSON report; never overwritten')
    args = parser.parse_args(argv)
    try:
        require(args.input.is_file() and not args.input.is_symlink(), 'input must be a regular file')
        document, input_digest = corpus.read_json(args.input, maximum_bytes=8000000)
        result = summarize(document, input_digest)
        require(corpus.read_json(args.input, maximum_bytes=8000000)[1] == input_digest,
                'input changed during scoring')
        publish_json(args.output, result)
        print(json.dumps({'gate': result['gate'], 'populationQualified': False}, sort_keys=True))
        return 1 if result['gate'] == 'fail' else 0
    except (corpus.CorpusError, OSError, TypeError, KeyError, ValueError):
        print('dictation benchmark: input or new output could not be admitted', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
