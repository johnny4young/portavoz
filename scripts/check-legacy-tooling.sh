#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Required legacy contracts; migrate with equivalent coverage before removal.
python3 scripts/ui_test_scope.py --validate-catalog
python3 -m unittest Tests.Tooling.test_collect_field_evidence
python3 -m unittest Tests.Tooling.test_release_reliability
python3 -m unittest Tests.Tooling.test_make_release
python3 -m unittest Tests.Tooling.test_release_notes
python3 -m unittest Tests.Tooling.test_deployment_floor
python3 -m unittest Tests.Tooling.test_site_interactions
python3 -m unittest Tests.Tooling.test_dev_install
python3 -m unittest Tests.Tooling.test_candidate_automation
python3 -m unittest Tests.Tooling.test_perf_binary
python3 -m unittest Tests.Tooling.test_perf_host_readiness
python3 -m unittest Tests.Tooling.test_apuntador_leak_baseline
python3 -m unittest Tests.Tooling.test_benchmark_watchdog
python3 -m unittest Tests.Tooling.test_source_integration_qualification
python3 -m unittest Tests.Tooling.test_verify_cloudkit_capabilities
python3 -m unittest Tests.Tooling.test_production_sync_qualification
python3 -m unittest Tests.Tooling.test_production_sync_qualification_packaging
python3 -m unittest Tests.Tooling.test_assistive_technology_qualification
python3 -m unittest Tests.Tooling.test_swift_test_failure_summary
python3 -m unittest Tests.Tooling.test_ci_workflow
python3 -m unittest Tests.Tooling.test_ci_swift_cache
python3 -m unittest Tests.Tooling.test_ci_time_report
python3 -m unittest Tests.Tooling.test_ci_swift_source_stamps
python3 -m unittest Tests.Tooling.test_ios_portability
python3 -m unittest Tests.Tooling.test_ui_nightly_health
python3 -m unittest Tests.Tooling.test_pr_evidence
python3 -m unittest Tests.Tooling.test_swift_test_scope
python3 -m unittest Tests.Tooling.test_ui_test_ci_gate
python3 -m unittest Tests.Tooling.test_ui_test_execution
python3 -m unittest Tests.Tooling.test_ui_interruption_evidence_archive
python3 -m unittest Tests.Tooling.test_ui_interruption_safety
python3 -m unittest Tests.Tooling.test_app_payload_permissions
python3 -m unittest Tests.Tooling.test_release_symbols
python3 -m unittest Tests.Tooling.test_ui_bundle_metadata
python3 -m unittest Tests.Tooling.test_ui_host
python3 -m unittest Tests.Tooling.test_ui_copy_policy
python3 -m unittest Tests.Tooling.test_dictation_corpus \
  Tests.Tooling.test_dictation_materialization Tests.Tooling.test_dictation_model_runner \
  Tests.Tooling.test_dictation_controller_runner Tests.Tooling.test_dictation_controller_matrix \
  Tests.Tooling.test_dictation_benchmark Tests.Tooling.test_dictation_field_corpus
python3 scripts/dictation_corpus.py verify-public
python3 -m unittest Tests.Tooling.test_dictation_search_quality
python3 scripts/dictation_search_quality.py verify-public
python3 -m unittest Tests.Tooling.test_commitment_quality
python3 scripts/commitment_quality.py validate \
  --fixture Fixtures/CommitmentQuality/public-synthetic-v1.json
python3 -m unittest Tests.Tooling.test_meeting_memory_graph_quality
python3 -m unittest Tests.Tooling.test_meeting_memory_graph_query_receipt
python3 scripts/meeting_memory_graph_quality.py verify-public \
  --fixture Fixtures/MeetingMemoryGraph/public-synthetic-v1.json
python3 -m unittest Tests.Tooling.test_commitment_link_quality
python3 -m unittest Tests.Tooling.test_commitment_link_policy_review
python3 scripts/commitment_link_quality.py validate \
  --fixture Fixtures/CommitmentLinkQuality/public-synthetic-v1.json
python3 -m unittest Tests.Tooling.test_resource_baseline
python3 -m unittest Tests.Tooling.test_resource_host_observation
python3 -m unittest Tests.Tooling.test_exact_path_matrix
python3 -m unittest Tests.Tooling.test_exact_path_mutation_matrix
python3 -m unittest Tests.Tooling.test_exact_path_mutation_cross_host
python3 -m unittest Tests.Tooling.test_exact_path_mutation_baseline
python3 -m unittest Tests.Tooling.test_exact_path_cross_host
python3 -m unittest Tests.Tooling.test_exact_path_baseline
python3 -m unittest Tests.Tooling.test_ask_quality
python3 -m unittest Tests.Tooling.test_ask_quality_pair
python3 -m unittest Tests.Tooling.test_ask_quality_attribution
python3 -m unittest Tests.Tooling.test_retrieval_chunk_resource_fixture
python3 -m unittest Tests.Tooling.test_retrieval_chunk_evidence
python3 -m unittest Tests.Tooling.test_semantic_scale_manifest
python3 scripts/ask_quality.py verify-public \
  --fixture Fixtures/AskQuality/public-synthetic-v1.json
python3 scripts/ask_quality.py verify-public \
  --fixture Fixtures/AskQuality/public-synthetic-v2.json
python3 scripts/retrieval_chunk_resource_fixture.py verify-public \
  --fixture Fixtures/RetrievalChunkResource/public-bilingual-homogeneous-v1.json
python3 -m unittest Tests.Tooling.test_apuntador_validation
python3 -m unittest Tests.Tooling.test_apuntador_web_fixture
python3 -m unittest Tests.Tooling.test_live_assist_validation
python3 -m unittest Tests.Tooling.test_live_question_training
python3 -m unittest Tests.Tooling.test_run_swift_tests
python3 -m unittest Tests.Tooling.test_run_xctest_pool
python3 scripts/apuntador_validation.py verify-public \
  --fixture Fixtures/ApuntadorValidation/public-bilingual-v1.json \
  --budget docs/evidence/apuntador-validation-budget.json
python3 scripts/apuntador_web_fixture.py verify-public \
  --fixture Fixtures/ApuntadorWeb/public-local-v1.json
python3 scripts/live_assist_validation.py verify-public \
  --fixture Fixtures/LiveAssistValidation/public-bilingual-v1.json \
  --budget docs/evidence/live-assist-validation-budget.json
python3 -m unittest Tests.Tooling.test_ui_test_scope
python3 -m unittest Tests.Tooling.test_first_install_site
python3 -m unittest Tests.Tooling.test_ui_test_runtime
python3 -m unittest Tests.Tooling.test_run_ui_tests
python3 -m unittest Tests.Tooling.test_ui_test_host_preflight
python3 -m unittest Tests.Tooling.test_meeting_detail_contract
python3 -m unittest Tests.Tooling.test_meeting_detail_performance
