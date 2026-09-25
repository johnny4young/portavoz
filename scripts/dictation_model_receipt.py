"""Closed admission for model-only observations, not an ASR quality threshold."""

from __future__ import annotations

import math
import re

import dictation_corpus as corpus


def number(value, maximum):
    return type(value) in (int, float) and 0 <= value <= maximum and math.isfinite(value)


def validate_score(score):
    corpus.exact_keys(score, 'wordErrorRate characterErrorRate referenceWords hypothesisWords '
                     'exactReferenceMatch legacyCleanupChangedText', 'model score schema mismatch')
    for key in ('wordErrorRate', 'characterErrorRate'):
        # Replay can legitimately exceed 100% error. Admission must not censor it.
        corpus.require(number(score[key], 1_000_000), 'invalid model error rate')
    for key in ('referenceWords', 'hypothesisWords'):
        corpus.require(corpus.integer(score[key], 0, 1_000_000), 'invalid model word count')
    for key in ('exactReferenceMatch', 'legacyCleanupChangedText'):
        corpus.require(type(score[key]) is bool, 'invalid model score flag')
    if score['exactReferenceMatch']:
        corpus.require(score['wordErrorRate'] == score['characterErrorRate'] == 0
                       and score['referenceWords'] == score['hypothesisWords'], 'inconsistent exact match')


def validate_attribution(value):
    corpus.exact_keys(value, 'vendorFinal mappedAndCoalesced matchesProductionText updateCount timingCount '
                     'rejectedAtBoundary rejectedBeforeBoundary mappedSegmentCount',
                     'stage attribution schema mismatch')
    corpus.require(type(value['matchesProductionText']) is bool, 'invalid attribution comparison')
    for key in ('updateCount', 'timingCount', 'rejectedAtBoundary', 'rejectedBeforeBoundary', 'mappedSegmentCount'):
        corpus.require(corpus.integer(value[key], 0, 100_000_000), 'invalid attribution count')
    corpus.require(value['mappedSegmentCount'] <= value['updateCount']
                   and value['rejectedAtBoundary'] + value['rejectedBeforeBoundary'] <= value['timingCount'],
                   'inconsistent attribution counts')
    for key in ('vendorFinal', 'mappedAndCoalesced'):
        validate_score(value[key])


def validate_work(work, frames, timeout, *, require_complete=True):
    counts = ('inputChunks', 'inputFrames', 'rejectedBuffers', 'backendUpdates', 'backendTokens',
              'backendTokenTimings', 'confirmedUpdates', 'updatesAfterFinishStarted', 'finishCalls')
    timings = ('loadMilliseconds', 'feedMilliseconds', 'finishMilliseconds',
               'updateDrainMilliseconds', 'cleanupMilliseconds')
    corpus.exact_keys(work, ' '.join(('channel', 'sampleRate', 'valid', 'outcome', *counts, *timings)),
                     'live work schema mismatch')
    for key in counts:
        corpus.require(corpus.integer(work[key], 0, 100_000_000), 'invalid live work count')
    for key in timings:
        corpus.require(number(work[key], timeout * 1_000), 'invalid live work duration')
    corpus.require(work['channel'] == 'microphone' and number(work['sampleRate'], 16_000)
                   and work['sampleRate'] == 16_000 and type(work['valid']) is bool
                   and work['outcome'] in ('completed', 'cancelled', 'failed'), 'invalid live work outcome')
    if require_complete:
        corpus.require(work['valid'] is True and work['outcome'] == 'completed'
                       and work['inputFrames'] == frames and work['inputChunks'] == (frames + 1_599) // 1_600
                       and work['rejectedBuffers'] == 0 and work['finishCalls'] == 1, 'live input conservation mismatch')
    corpus.require(work['confirmedUpdates'] <= work['backendUpdates']
                   and work['updatesAfterFinishStarted'] <= work['backendUpdates'], 'inconsistent live update counts')


def validate_observation(receipt, request, cells, entries):
    corpus.exact_keys(receipt, 'kind schemaVersion corpusSHA256 manifestSHA256 modelID modelRevision '
                     'modelVerificationSeconds modelLoadSeconds loadState localeMode feed qualityMeasured '
                     'controllerMeasured verifiedDeliveryMeasured memoryMeasured backendWindowFailureCoverageMeasured '
                     'repetitions cells', 'model observation schema mismatch')
    fixed = {'kind': 'dictation-installed-model-observation', 'schemaVersion': 2,
             'corpusSHA256': corpus.CORPUS_SHA256, 'manifestSHA256': request['manifestSHA256'],
             'modelID': 'parakeet-tdt-0.6b-v3-coreml', 'loadState': 'new-engine-uncontrolled-coreml-disk-cache',
             'localeMode': 'automatic-no-vocabulary', 'feed': 'realtime-100ms-bounded-pcm',
             'qualityMeasured': True, 'controllerMeasured': False, 'verifiedDeliveryMeasured': False,
             'memoryMeasured': False, 'backendWindowFailureCoverageMeasured': False,
             'repetitions': request['repetitions']}
    corpus.require(all(type(receipt[key]) is type(value) and receipt[key] == value for key, value in fixed.items()),
                   'model observation identity or scope mismatch')
    corpus.require(type(receipt['modelRevision']) is str
                   and re.fullmatch(r'[0-9a-f]{40}', receipt['modelRevision']) is not None, 'invalid model revision')
    for key in ('modelVerificationSeconds', 'modelLoadSeconds'):
        corpus.require(number(receipt[key], request['timeoutSeconds']), 'invalid model preparation duration')
    rows = receipt['cells']
    expected = [(case, attempt) for attempt in (1, 2) for case in request['cases']]
    corpus.require(type(rows) is list and len(rows) == len(expected), 'model observation is incomplete')
    for row, (case, attempt) in zip(rows, expected):
        family, _ = cells[case]
        validate_row(row, case, attempt, family, entries[case], request)


def validate_row(row, case, attempt, family, entry, request):
    corpus.require(type(row) is dict, 'model cell must be an object')
    # Swift omits a nil first-update time for a stream that emits no captions.
    optional = ' firstUpdateSeconds' if 'firstUpdateSeconds' in row else ''
    if request['stageAttribution']:
        optional += ' stageAttribution'
    corpus.exact_keys(row, 'caseID audioSHA256 group cohort shape split critical pass repetitions score adapterDeltas '
                     'inputSeconds completionSeconds inputEndSeconds work' + optional, 'model cell schema mismatch')
    corpus.require(row['caseID'] == case and type(row['pass']) is int and row['pass'] == attempt
                   and type(row['repetitions']) is int and row['repetitions'] == request['repetitions'],
                   'model observation selection mismatch')
    corpus.require(row['audioSHA256'] == entry['audioSHA256']
                   and all(row[key] == family[key] for key in ('group', 'cohort', 'shape', 'split'))
                   and type(row['critical']) is bool and row['critical'] == family['critical'],
                   'model cell source attribution mismatch')
    frames = entry['frames'] * request['repetitions']
    for key in ('inputSeconds', 'inputEndSeconds', 'completionSeconds'):
        corpus.require(number(row[key], request['timeoutSeconds']), 'invalid model cell duration')
    corpus.require(row['inputSeconds'] == frames / 16_000
                   and row['inputSeconds'] <= row['inputEndSeconds'] <= row['completionSeconds'],
                   'model observation duration mismatch')
    if 'firstUpdateSeconds' in row:
        corpus.require(number(row['firstUpdateSeconds'], row['completionSeconds']), 'invalid first update duration')
    for key in ('score', 'adapterDeltas'):
        validate_score(row[key])
    if 'firstUpdateSeconds' not in row:
        corpus.require(row['score']['hypothesisWords'] == row['adapterDeltas']['hypothesisWords'] == 0,
                       'nonempty output requires a first update observation')
    corpus.require(row['adapterDeltas']['legacyCleanupChangedText'] is False, 'adapter deltas cannot claim cleanup')
    validate_work(row['work'], frames, request['timeoutSeconds'])
    if request['stageAttribution']:
        validate_attribution(row['stageAttribution'])
