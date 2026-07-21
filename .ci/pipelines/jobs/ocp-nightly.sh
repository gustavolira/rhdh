#!/bin/bash

# shellcheck source=.ci/pipelines/lib/log.sh
source "$DIR"/lib/log.sh
# shellcheck source=.ci/pipelines/lib/common.sh
source "$DIR"/lib/common.sh
# shellcheck source=.ci/pipelines/utils.sh
source "$DIR"/utils.sh
# shellcheck source=.ci/pipelines/lib/testing.sh
source "$DIR"/lib/testing.sh
# shellcheck source=.ci/pipelines/playwright-projects.sh
source "$DIR"/playwright-projects.sh
# shellcheck source=.ci/pipelines/lib/schema-mode-env.sh
source "$DIR"/lib/schema-mode-env.sh

handle_ocp_nightly() {
  export NAME_SPACE="${NAME_SPACE:-showcase-ci-nightly}"
  export NAME_SPACE_RBAC="${NAME_SPACE_RBAC:-showcase-rbac-nightly}"
  export NAME_SPACE_POSTGRES_DB="${NAME_SPACE_POSTGRES_DB:-postgress-external-db-nightly}"

  common::oc_login

  K8S_CLUSTER_ROUTER_BASE=$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//')
  export K8S_CLUSTER_ROUTER_BASE

  cluster_setup_ocp_helm

  if [[ "${JOB_NAME}" == *osd-gcp* ]]; then
    log::info "Detected OSD-GCP job, using OSD-GCP specific deployment"
    initiate_deployments_osd_gcp "${PW_PROJECT_SHOWCASE}" "${PW_PROJECT_SHOWCASE_RBAC}"
  else
    initiate_deployments "${PW_PROJECT_SHOWCASE}" "${PW_PROJECT_SHOWCASE_RBAC}"
  fi

  deploy_test_backstage_customization_provider "${NAME_SPACE}"

  run_standard_deployment_tests
  run_runtime_config_change_tests
  run_sanity_plugins_check
}

run_standard_deployment_tests() {
  local url="https://${RELEASE_NAME}-developer-hub-${NAME_SPACE}.${K8S_CLUSTER_ROUTER_BASE}"
  testing::check_and_test "${RELEASE_NAME}" "${NAME_SPACE}" "${PW_PROJECT_SHOWCASE}" "${url}"
  local rbac_url="https://${RELEASE_NAME_RBAC}-developer-hub-${NAME_SPACE_RBAC}.${K8S_CLUSTER_ROUTER_BASE}"
  testing::check_and_test "${RELEASE_NAME_RBAC}" "${NAME_SPACE_RBAC}" "${PW_PROJECT_SHOWCASE_RBAC}" "${rbac_url}"
}

run_runtime_config_change_tests() {
  # Runtime tests handle their own deployment via TypeScript (runtime-deploy.ts).
  # The first test file (config-map.spec.ts) calls ensureRuntimeDeployed() which:
  #   - Creates the namespace
  #   - Deploys RHDH with Helm + internal PostgreSQL sub-chart
  #   - Configures schema-mode env vars for port-forwarding
  # Subsequent test files reuse the existing deployment (workers: 1).
  #
  # The CI wrapper only needs to set environment variables and invoke Playwright.

  export INSTALL_METHOD="helm"
  local runtime_url="https://${RELEASE_NAME}-developer-hub-${NAME_SPACE_RUNTIME}.${K8S_CLUSTER_ROUTER_BASE}"
  testing::run_tests "${RELEASE_NAME}" "${NAME_SPACE_RUNTIME}" "${PW_PROJECT_SHOWCASE_RUNTIME}" "${runtime_url}" || true
}

run_sanity_plugins_check() {
  # Both sanity flavors derive their plugin set from the SAME catalog index:
  # the cluster deployment (chart global.catalogIndex + generated enable
  # values) and the cluster-free check below. Exported here, BEFORE the Helm
  # install, so the chart receives it; overridable via Gangway
  # (--catalog-index-image) for RC verification. The derived CATALOG_INDEX_*
  # components come from the shared helper in env_variables.sh, which leaves
  # them empty when no override is set.
  #
  # The default is the index the chart values ALREADY pin - not
  # plugin-catalog-index:${RELEASE_VERSION}. The chart uses the index's
  # dynamic-plugins.default.yaml as its `includes` file, which is where every
  # ./dynamic-plugins/dist plugin gets its default pluginConfig. A branch-matched
  # tag is not interchangeable: :next currently carries 9 packages and zero dist
  # refs, versus 53 packages and 41 dist refs in the pinned :1.10. Pointing the
  # deployment at it silently stripped the dynamicRoutes of every in-image plugin
  # - the home page 404'd and the smoke test failed.
  if [[ -z "${CATALOG_INDEX_IMAGE:-}" ]]; then
    local pinned_index
    pinned_index="$(yq -r '
      [.global.catalogIndex.image.registry, "/", .global.catalogIndex.image.repository, ":", .global.catalogIndex.image.tag] | join("")
    ' "${DIR}/value_files/${HELM_CHART_VALUE_FILE_NAME}" 2> /dev/null)"
    if [[ -z "${pinned_index}" || "${pinned_index}" == *null* ]]; then
      log::error "Could not read global.catalogIndex.image from ${HELM_CHART_VALUE_FILE_NAME}"
      return 1
    fi
    export CATALOG_INDEX_IMAGE="${pinned_index}"
  fi
  log::info "Sanity plugins catalog index: ${CATALOG_INDEX_IMAGE}"
  catalog_index::export_components "${CATALOG_INDEX_IMAGE}"

  local sanity_plugins_url="https://${RELEASE_NAME}-developer-hub-${NAME_SPACE_SANITY_PLUGINS_CHECK}.${K8S_CLUSTER_ROUTER_BASE}"
  initiate_sanity_plugin_checks_deployment "${RELEASE_NAME}" "${NAME_SPACE_SANITY_PLUGINS_CHECK}" "${sanity_plugins_url}" "${PW_PROJECT_SHOWCASE_SANITY_PLUGINS}"
  testing::check_and_test "${RELEASE_NAME}" "${NAME_SPACE_SANITY_PLUGINS_CHECK}" "${PW_PROJECT_SHOWCASE_SANITY_PLUGINS}" "${sanity_plugins_url}"
  # Name the culprit plugin(s) loudly when the deployment or tests failed -
  # a broken plugin takes the whole pod down, and the answer is buried in the
  # pod logs otherwise. Advisory: prints nothing fatal on healthy runs.
  testing::report_plugin_startup_failures "${NAME_SPACE_SANITY_PLUGINS_CHECK}" "${PW_PROJECT_SHOWCASE_SANITY_PLUGINS}"

  # Cluster-free counterpart (RHIDP-13508): boots packages/backend from source
  # inside the test pod with EVERY plugin the catalog index declares and
  # verifies the product's dynamic plugin loader loaded all of them. The
  # cluster deployment above validates the curated plugin set on the shipped
  # image; this validates the full index composition against the current
  # backend line. The function records its own result via test_run_tracker and
  # save_overall_result (like testing::run_tests), so a failure here marks the
  # job without aborting remaining steps.
  testing::run_plugin_sanity_check "plugin-dynamic-loading" || true
}
