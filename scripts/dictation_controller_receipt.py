"""Admit actual-controller observations without claiming native insertion."""

import re

import dictation_corpus as corpus
from dictation_model_receipt import number, validate_score, validate_work


def validate_observation(receipt, request, cells, entries):
    fixed = {
        'kind': 'dictation-controller-model-observation', 'schemaVersion': 1,
        'corpusSHA256': corpus.CORPUS_SHA256, 'manifestSHA256': request['manifestSHA256'],
        'modelID': 'parakeet-tdt-0.6b-v3-coreml',
        'loadState': 'lazy-shared-engine-uncontrolled-coreml-disk-cache',
        'localeMode': 'automatic-literal-no-vocabulary', 'feed': 'realtime-100ms-public-pcm-controller-stop',
        'evaluationTarget': 'proposed-output-including-cancelled-and-failed-attempts',
        'qualityMeasured': True, 'controllerMeasured': True, 'verifiedDeliveryMeasured': False,
        'platformChecksMeasured': False, 'memoryMeasured': True,
        'memoryScope': 'sampled-whole-xctest-process-not-allocation-attribution',
        'backendWindowFailureCoverageMeasured': False, 'repetitions': request['repetitions'],
    }
    corpus.exact_keys(receipt, ' '.join((*fixed, 'modelRevision', 'modelVerificationSeconds', 'modelLoadSeconds', 'modelLoadAttempts', 'cells')),
                     'controller observation schema mismatch')
    corpus.require(all(type(receipt[k]) is type(v) and receipt[k] == v for k, v in fixed.items()),
                   'controller observation identity or scope mismatch')
    corpus.require(type(receipt['modelRevision']) is str and re.fullmatch(r'[0-9a-f]{40}', receipt['modelRevision']),
                   'invalid model revision')
    for key in ('modelVerificationSeconds', 'modelLoadSeconds'):
        corpus.require(number(receipt[key], request['timeoutSeconds']), 'invalid model preparation time')
    expected = [(case, attempt) for attempt in (1, 2) for case in request['cases']]
    corpus.require(type(receipt['cells']) is list and len(receipt['cells']) == len(expected), 'incomplete controller rows')
    ready = False
    attempts = 0
    for row, (case, attempt) in zip(receipt['cells'], expected):
        validate_row(row, case, attempt, ready, cells[case][0], entries[case], request)
        attempts += not ready
        ready |= 'runtimeReady' in row['controller']['elapsedSeconds']
    corpus.require(type(receipt['modelLoadAttempts']) is int and receipt['modelLoadAttempts'] == attempts,
                   'runtime preparation attempts mismatch')
    load_window = sum(row['controller']['terminalSeconds'] for row in receipt['cells']
                      if row['runtimeState'] == 'first-engine-load')
    corpus.require(receipt['modelLoadSeconds'] <= load_window, 'runtime loading exceeded its controller requests')


def validate_row(row, case, attempt, ready, family, entry, request):
    corpus.exact_keys(row, 'caseID audioSHA256 group cohort shape split critical pass repetitions inputSeconds '
                     'runtimeState proposedOutputScore controller footprint inputCompleted fedFrames pipelineCompleted work', 'controller row schema mismatch')
    corpus.require(row['caseID'] == case and type(row['pass']) is int and row['pass'] == attempt
                   and type(row['repetitions']) is int and row['repetitions'] == request['repetitions'],
                   'controller selection mismatch')
    corpus.require(row['audioSHA256'] == entry['audioSHA256']
                   and all(row[key] == family[key] for key in ('group', 'cohort', 'shape', 'split'))
                   and type(row['critical']) is bool and row['critical'] == family['critical'],
                   'controller source attribution mismatch')
    frames = entry['frames'] * request['repetitions']
    corpus.require(number(row['inputSeconds'], request['timeoutSeconds']) and row['inputSeconds'] == frames / 16_000,
                   'controller input duration mismatch')
    corpus.require(row['runtimeState'] == ('reused-engine' if ready else 'first-engine-load'),
                   'controller runtime reuse mismatch')
    validate_score(row['proposedOutputScore'])
    corpus.require(row['proposedOutputScore']['legacyCleanupChangedText'] is False, 'controller profile is literal')
    corpus.require(type(row['inputCompleted']) is bool and type(row['pipelineCompleted']) is bool
                   and corpus.integer(row['fedFrames'], 0, frames), 'invalid controller input accounting')
    corpus.require(type(row['work']) is list and len(row['work']) <= 1, 'invalid public live-work observation count')
    for work in row['work']:
        validate_work(work, frames, request['timeoutSeconds'], require_complete=False)
    corpus.require(type(row['controller']) is dict, 'controller timings must be an object')
    complete = row['inputCompleted'] and row['fedFrames'] == frames and len(row['work']) == 1
    complete = complete and row['controller'].get('outcome') in ('empty', 'deliveryRejected')
    if complete:
        work = row['work'][0]
        complete = (work['valid'] is True and work['outcome'] == 'completed' and work['inputFrames'] == frames
                    and work['inputChunks'] == (frames + 1_599) // 1_600
                    and work['rejectedBuffers'] == 0 and work['finishCalls'] == 1)
    corpus.require(row['pipelineCompleted'] is complete, 'forged controller pipeline completion')
    validate_controller(row['controller'], row['proposedOutputScore'], row['inputSeconds'],
                        request['timeoutSeconds'], complete)
    validate_footprint(row['footprint'], request['timeoutSeconds'])


def validate_controller(value, score, input_seconds, timeout, complete):
    corpus.exact_keys(value, 'schemaVersion elapsedSeconds terminalSeconds outcome verifiedDeliveryMeasured',
                     'controller timings schema mismatch')
    corpus.require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1
                   and value['verifiedDeliveryMeasured'] is False
                   and value['outcome'] in ('empty', 'deliveryRejected', 'cancelled', 'pipelineFailed'),
                   'invalid controller outcome')
    corpus.require(number(value['terminalSeconds'], timeout), 'invalid controller outcome duration')
    allowed = {'runtimeReady', 'microphoneReady', 'firstBufferHandled', 'firstCaptionHandled',
               'stopRequested', 'inputEnded', 'transcriptionEnded', 'textPrepared', 'deliveryStarted', 'deliveryReturned'}
    phases = value['elapsedSeconds']
    corpus.require(type(phases) is dict and phases.keys() <= allowed, 'unexpected controller timing')
    corpus.require(all(number(value, timeout) for value in phases.values())
                   and all(elapsed <= value['terminalSeconds'] for elapsed in phases.values()), 'invalid controller timing')
    if 'microphoneReady' in phases:
        corpus.require('runtimeReady' in phases and phases['runtimeReady'] <= phases['microphoneReady'],
                       'microphone precedes runtime acquisition')
    for point, terminal in (('firstBufferHandled', 'inputEnded'), ('firstCaptionHandled', 'transcriptionEnded')):
        if point in phases:
            corpus.require('microphoneReady' in phases and phases['microphoneReady'] <= phases[point],
                           'input or caption precedes microphone readiness')
            if terminal in phases:
                corpus.require(phases[point] <= phases[terminal], 'first observation follows stream termination')
    if 'textPrepared' in phases:
        corpus.require({'inputEnded', 'transcriptionEnded'} <= phases.keys()
                       and max(phases['inputEnded'], phases['transcriptionEnded']) <= phases['textPrepared'],
                       'final text precedes stream termination')
    if value['outcome'] == 'deliveryRejected':
        required = {'firstCaptionHandled', 'textPrepared', 'deliveryStarted', 'deliveryReturned'}
        corpus.require(required <= phases.keys() and score['hypothesisWords'] > 0
                       and phases['textPrepared'] <= phases['deliveryStarted'] <= phases['deliveryReturned'],
                       'incomplete proposed output delivery boundary')
    else:
        corpus.require(score['hypothesisWords'] == 0 and 'deliveryStarted' not in phases
                       and 'deliveryReturned' not in phases, 'undelivered attempt cannot claim proposed output')
    if complete:
        required = {'runtimeReady', 'microphoneReady', 'firstBufferHandled', 'stopRequested',
                    'inputEnded', 'transcriptionEnded', 'textPrepared'}
        corpus.require(required <= phases.keys() and phases['microphoneReady'] <= phases['stopRequested']
                       and phases['microphoneReady'] + input_seconds <= phases['inputEnded'],
                       'completed pipeline is missing its input boundaries')


def validate_footprint(value, timeout):
    corpus.exact_keys(value, 'baselineBytes peakObservedBytes endingBytes sampleCount cadenceMilliseconds '
                     'initialThermalState finalThermalState', 'footprint schema mismatch')
    for key in ('baselineBytes', 'peakObservedBytes', 'endingBytes'):
        corpus.require(corpus.integer(value[key], 1, 2**64 - 1), 'invalid footprint size')
    corpus.require(value['peakObservedBytes'] >= max(value['baselineBytes'], value['endingBytes'])
                   and corpus.integer(value['sampleCount'], 2, int(timeout * 10) + 2)
                   and type(value['cadenceMilliseconds']) is int and value['cadenceMilliseconds'] == 100,
                   'invalid footprint observation')
    for key in ('initialThermalState', 'finalThermalState'):
        corpus.require(value[key] in ('nominal', 'fair', 'serious', 'critical'), 'invalid thermal observation')
