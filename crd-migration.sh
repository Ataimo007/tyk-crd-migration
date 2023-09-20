#!/usr/bin/env bash

is_cleanable=1
operatorcontext=""
source_operator_namespace=""
destination_operator_namespace=""
operatorcontext_namespace=""
source_kubeconfig=""
destination_kubeconfig=""
operator_replica_count=1
source_namespace=""
backup_directory="./backup/"
live_directory="./live/"
operations_directory="./.operations/"
source_operatorcontext=""
source_operatorcontext_namespace=""

declare -A scanned_crds
declare -A backedup_crds
declare -A migrated_crds
declare -A cleanedup_crds
current_context=""

get_source_webhook_dir() {
  local dir="$operations_directory"source/
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_destination_webhook_dir() {
  local dir="$operations_directory"destination/
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_backup_dir() {
  local dir

  if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
    dir="$backup_directory""$source_namespace"/"$source_operatorcontext"/
  else
    dir="$backup_directory""$source_namespace"/
  fi

  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_live_dir() {
  local dir

  if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
    dir="$live_directory""$source_namespace"/"$source_operatorcontext"/
  else
    dir="$live_directory""$source_namespace"/
  fi

  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_crd_backup_dir() {
  local dir

  dir="$(get_backup_dir)$1"
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_crd_live_dir() {
  local dir

  dir="$(get_live_dir)$1"
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

clean() {
  local i=0

  if [[ $source_operatorcontext == "" && $source_operatorcontext_namespace == "" ]]; then
    for name in $(kubectl get "$1" -n "$source_namespace" -o name --context "$current_context"); do
      name="${name##*/}"

      if [[ $2 != "" ]]; then
        if [[ -f "${2}"/"${name}".yaml ]]; then
          delete_k8s_object "$name" "$1" "$source_namespace"
          echo "Deleted $(friendly_name "$1") $name"
          i=$((i + 1))
        fi
      else
        delete_k8s_object "$name" "$1" "$source_namespace"
        echo "Deleted $(friendly_name "$1") $name"
        i=$((i + 1))
      fi

    done
  else
    while read -r line; do
      name="$(echo "$line" | awk '{print $1}')"
      context_name="$(echo "$line" | awk '{print $2}')"
      context_namespace="$(echo "$line" | awk '{print $3}')"

      if [[ $context_name == "$source_operatorcontext" && $context_namespace == "$source_operatorcontext_namespace" ]]; then

        if [[ $2 != "" ]]; then
          if [[ -f "${2}"/"${name}".yaml ]]; then
            delete_k8s_object "$name" "$1" "$source_namespace"
            echo "Deleted $(friendly_name "$1") $name"
            i=$((i + 1))
          fi
        else
          delete_k8s_object "$name" "$1" "$source_namespace"
          echo "Deleted $(friendly_name "$1") $name"
          i=$((i + 1))
        fi

      fi
    done <<<"$(kubectl get "$1" -n "$source_namespace" -o=custom-columns='name:.metadata.name,context-name:.spec.contextRef.name,context-namespace:.spec.contextRef.namespace' --no-headers --context "$current_context")"
  fi

  cleanedup_crds["$1"]=$i
}

backup() {
  local i=0

  if [[ $source_operatorcontext == "" && $source_operatorcontext_namespace == "" ]]; then
    for name in $(kubectl get "$1" -n "$source_namespace" -o name --context "$current_context"); do
      name="${name##*/}"
      kubectl get "${1}" "${name}" -n "$source_namespace" -o yaml --context "$current_context" >"${2}"/"${name}".yaml
      echo "Backed Up $(friendly_name "$1") $name"
      i=$((i + 1))
    done
  else
    while read -r line; do
      name="$(echo "$line" | awk '{print $1}')"
      context_name="$(echo "$line" | awk '{print $2}')"
      context_namespace="$(echo "$line" | awk '{print $3}')"

      if [[ $context_name == "$source_operatorcontext" && $context_namespace == "$source_operatorcontext_namespace" ]] || [[ $1 == "operatorcontexts" ]]; then
        kubectl get "${1}" "${name}" -n "$source_namespace" -o yaml --context "$current_context" >"${2}"/"${name}".yaml
        echo "Backed Up $(friendly_name "$1") $name"
        i=$((i + 1))
      fi
    done <<<"$(kubectl get "$1" -n "$source_namespace" -o=custom-columns='name:.metadata.name,context-name:.spec.contextRef.name,context-namespace:.spec.contextRef.namespace' --no-headers --context "$current_context")"
  fi

  backedup_crds["$1"]=$i
}

restore() {
  local files crd i=0

  files=$(ls "$1")

  for file in $files; do
    crd=$(cat "$1"/"$file")

    if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
      crd_context_name=$(echo "$crd" | yq '.spec.contextRef.name' -)
      crd_context_namespace=$(echo "$crd" | yq '.spec.contextRef.namespace' -)

      if ! [[ $source_operatorcontext == "$crd_context_name" && $source_operatorcontext_namespace == "$crd_context_namespace" ]]; then
        continue
      fi
    fi

    if [ "$3" == "apidefinitions" ]; then
      crd=$(indemnify_api "$crd")
    fi
    if [ "$3" == "securitypolicies" ]; then
      crd=$(indemnify_policy "$crd")
    fi

    crd=$(prepare "$crd")
    store "$crd" "$2/$file"
    apply "$crd"

    echo "Restored $(friendly_name "$3") $file"
    i=$((i + 1))
  done

  migrated_crds["$3"]=$i
}

scan() {
  local i=0

  if [[ $source_operatorcontext == "" && $source_operatorcontext_namespace == "" ]]; then
    for name in $(kubectl get "$1" -n "$source_namespace" -o name --context "$current_context"); do
      i=$((i + 1))
    done
  else
    while read -r line; do
      context_name="$(echo "$line" | awk '{print $2}')"
      context_namespace="$(echo "$line" | awk '{print $3}')"

      if [[ $context_name == "$source_operatorcontext" && $context_namespace == "$source_operatorcontext_namespace" ]] || [[ $1 == "operatorcontexts" ]]; then
        i=$((i + 1))
      fi
    done <<<"$(kubectl get "$1" -n "$source_namespace" -o=custom-columns='name:.metadata.name,context-name:.spec.contextRef.name,context-namespace:.spec.contextRef.namespace' --no-headers --context "$current_context")"
  fi

  scanned_crds["$1"]=$i
}

report_migration() {
  local backup live

  printf "\n\nMigration Report:\n"

  for i in "${!scanned_crds[@]}"; do
    if [[ ${scanned_crds[$i]} -gt 0 ]]; then
      if [[ $i == "operatorcontexts" ]]; then
        echo "$(friendly_name "$i") Report: ${scanned_crds[$i]} Found, ${backedup_crds[$i]} Backed Up"
      else
        echo "$(friendly_name "$i") Report: ${scanned_crds[$i]} Found, ${backedup_crds[$i]} Backed Up, ${migrated_crds[$i]} Migrated"
      fi
    fi
  done

  for i in "${!scanned_crds[@]}"; do
    if [[ ${scanned_crds[$i]} -eq 0 ]]; then
      echo "No $(friendly_name "$i") Found"
    fi
  done

  backup=$(get_backup_dir)
  live=$(get_live_dir)
  echo "Back Up CRDs Directory: $(pwd)${backup##*.}"
  echo "Live CRDs Directory: $(pwd)${live##*.}"
  echo "Migration Complete"
}

report_cleanup() {
  printf "\n\nClean Up Report:\n"

  for i in "${!scanned_crds[@]}"; do
    if [[ ${scanned_crds[$i]} -gt 0 ]]; then
      if [[ $i == "operatorcontexts" ]]; then
        echo "$(friendly_name "$i") Report: ${scanned_crds[$i]} Found"
      else
        echo "$(friendly_name "$i") Report: ${scanned_crds[$i]} Found, ${cleanedup_crds[$i]} Cleaned Up"
      fi
    fi
  done

  for i in "${!scanned_crds[@]}"; do
    if [[ ${scanned_crds[$i]} -eq 0 ]]; then
      echo "No $(friendly_name "$i") Found"
    fi
  done

  echo "Clean Up Complete"
}

scan_crds() {
  for crd in $(kubectl get crd -o name | grep tyk); do
    crd="${crd##*/}"
    crd="${crd%%.*}"

    scan "$crd"
    echo "Discovered ${scanned_crds[$crd]} $(friendly_name "$crd")"
  done
}

backup_crds() {
  for crd in $(kubectl get crd -o name | grep tyk); do
    crd="${crd##*/}"
    crd="${crd%%.*}"

    if [[ ${scanned_crds[$crd]} -gt 0 ]]; then
      echo "Backing Up $(friendly_name "$crd")"
      backup "$crd" "$(get_crd_backup_dir "$crd")"
      echo "Backed Up ${backedup_crds[$crd]} $(friendly_name "$crd")"
    fi

  done
}

migrate_crds() {
  switch_kubeconfig "$destination_kubeconfig"

  for crd in $(kubectl get crd -o name | grep tyk); do
    crd="${crd##*/}"
    crd="${crd%%.*}"

    if [[ ${scanned_crds[$crd]} -gt 0 && $crd != "operatorcontexts" ]]; then
      echo "Migrating $(friendly_name "$crd")"
      restore "$(get_crd_backup_dir "$crd")" "$(get_crd_live_dir "$crd")" "$crd"
      echo "Migrated ${migrated_crds[$crd]} $(friendly_name "$crd")"
    fi

  done

  switch_kubeconfig "$source_kubeconfig"
}

cleanup_crds() {
  if [[ ${scanned_crds[securitypolicies]} -gt 0 ]]; then
    clean_crds "securitypolicies" "$1"
  fi

  for crd in $(kubectl get crd -o name | grep tyk); do
    crd="${crd##*/}"
    crd="${crd%%.*}"

    if [[ ${scanned_crds[$crd]} -gt 0 && $crd != "operatorcontexts" && $crd != "securitypolicies" ]]; then
      clean_crds "$crd" "$1"
    fi

  done
}

clean_crds() {
  echo "Cleaning Up $(friendly_name "$1")"

  if [ "$2" != "" ]; then
    if [ "$2" == "-" ]; then
      clean "$1" "$(get_crd_backup_dir "$1")"
    else
      clean "$1" "$2/$1"
    fi
  else
    clean "$1"
  fi

  echo "Cleaned Up ${cleanedup_crds[$1]} $(friendly_name "$1")"
}

are_crds_available() {
  for i in "${!scanned_crds[@]}"; do
    if [[ ${scanned_crds[$i]} -gt 0 ]]; then
      echo 1
      return
    fi
  done
  echo 0
}

scan_namespace() {
  if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
    echo "Scanning $source_namespace Namespace of $(get_kubeconfig) Kubernetes Context for CRDs associated with $source_operatorcontext Operator Context"
  else
    echo "Scanning $source_namespace Namespace of $(get_kubeconfig) Kubernetes Context for CRDs"
  fi

  scan_crds
}

backup_namespace() {
  if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
    echo "Backing Up all CRDs in $source_namespace Namespace of $(get_kubeconfig) Kubernetes Context associated with $source_operatorcontext Operator Context"
  else
    echo "Backing Up all CRDs in $source_namespace Namespace of $(get_kubeconfig) Kubernetes Context"
  fi

  backup_crds
}

migrate_namespace() {
  if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
    echo "Migrating CRDs associated with $source_operatorcontext Operator Context, from Backup to $destination_kubeconfig Kubernetes Context"
  else
    echo "Migrating CRDs from Backup to $destination_kubeconfig Kubernetes Context"
  fi

  migrate_crds
}

clean_namespace() {
  if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
    if [ "$1" != "" ]; then
      echo "Cleaning Up Backed Up CRDs associated with $source_operatorcontext"
    else
      echo "Cleaning Up CRDs associated with $source_operatorcontext"
    fi
  else
    echo "Cleaning Up CRDs"
  fi

  cleanup_crds "$1"
}

find_k8s_object() {
  local name k8s_object=""
  while read -r line; do
    name="$(echo "$line" | awk '{print $1}')"
    # if [[ $line == *"$2"* ]]; then
    if [[ $name == "$2" ]]; then
      k8s_object="$(echo "$line" | awk '{print $2}')"
      echo "$k8s_object"
      return
    fi
  done <<<"$(kubectl get "$1" -A -o=custom-columns='name:.metadata.name,namespace:.metadata.namespace' --no-headers --context "$current_context")"
  echo "$k8s_object"
}

verify_k8s_object() {
  while read -r line; do
    name="$(echo "$line" | awk '{print $1}')"
    if [[ $name == "$2" ]]; then
      echo 1
      return
    fi
  done <<<"$(kubectl get "$1" -n "$3" -o=custom-columns='name:.metadata.name,namespace:.metadata.namespace' --no-headers --context "$current_context")"
  echo 0
}

find_source_operator() {
  source_operator_namespace=$(find_k8s_object "deployments" "tyk-operator-controller-manager")
  if [ "$source_operator_namespace" == "" ]; then
    echo "No Operator found in the Source Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
  echo "Source Operator exists in the Source Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
}

find_destination_operator() {
  destination_operator_namespace=$(find_k8s_object "deployments" "tyk-operator-controller-manager")
  if [ "$destination_operator_namespace" == "" ]; then
    echo "No Operator found in the Destination Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
  echo "Destination Operator exists in the Destination Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
}

validate_source_namespace() {
  namespaceStatus=$(kubectl get ns "$1" -o yaml --context "$current_context" 2>/dev/null | yq .status.phase -r)
  if [ "$namespaceStatus" == "Active" ]; then
    source_namespace=$1
    echo "Source Namespace $source_namespace exists in the Source Kubernetes Context $(get_kubeconfig)"
  else
    echo "The Source Namespace $1 doesn't exist in Kubernetes Context $(get_kubeconfig)"
  fi
}

validate_destination_namespace() {
  namespaceStatus=$(kubectl get ns "$source_namespace" -o yaml --context "$current_context" 2>/dev/null | yq .status.phase -r)
  if [ "$namespaceStatus" == "Active" ]; then
    echo "Source Namespace $source_namespace is also present in Kubernetes Context $(get_kubeconfig)"
  else
    kubectl create ns "$source_namespace" --context "$current_context" >/dev/null
    echo "Created Source Namespace $source_namespace in Kubernetes Context $(get_kubeconfig)"
  fi
}

validate_destination_context() {
  switch_kubeconfig "$destination_kubeconfig"
  find_destination_operator
  find_operatorcontext "$1"
  validate_destination_namespace
  switch_kubeconfig "$source_kubeconfig"
}

validate_source_context() {
  if [ "$source_kubeconfig" != "" ]; then
    switch_kubeconfig "$source_kubeconfig"
    find_source_operator

    if [ "$2" != "-" ]; then
      find_source_operatorcontext "$2"
    fi

    validate_source_namespace "$1"
  fi
}

find_operatorcontext() {
  local ns oc namespace context

  if [[ $1 == *"/"* ]]; then
    ns="$(echo "$1" | awk -F / '{print $1}')"
    oc="$(echo "$1" | awk -F / '{print $2}')"
    echo "Verifying if the Destination Opertor Context $oc exist in the Namespace $ns"
    if [ "$(verify_k8s_object "operatorcontext" "$oc" "$ns")" ]; then
      namespace=$ns
      context=$oc
    fi
  else
    echo "Finding the Namespace for the Destination Opertor Context $1"
    namespace=$(find_k8s_object "operatorcontext" "$1")
    context=$1
  fi

  if [[ "$namespace" != "" && "$context" != "" ]]; then
    operatorcontext=$context
    operatorcontext_namespace=$namespace
    echo "Destination Operator Context $operatorcontext exists in the Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  else
    echo "Destination Operator Context $context wasn't found in Current Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
}

find_source_operatorcontext() {
  local ns oc namespace context

  if [[ $1 == */* ]]; then
    ns="$(echo "$1" | awk -F / '{print $1}')"
    oc="$(echo "$1" | awk -F / '{print $2}')"
    echo "Verifying if the Source Opertor Context $oc exist in the Namespace $ns"
    if [ "$(verify_k8s_object "operatorcontext" "$oc" "$ns")" ]; then
      namespace=$ns
      context=$oc
    fi
  else
    echo "Finding the Namespace for the Source Opertor Context $1"
    namespace=$(find_k8s_object "operatorcontext" "$1")
    context=$1
  fi

  if [[ "$namespace" != "" && "$context" != "" ]]; then
    source_operatorcontext=$context
    source_operatorcontext_namespace=$namespace
    echo "Source Operator Context $source_operatorcontext in Namespace $source_operatorcontext_namespace of the Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  else
    echo "Source Operator Context $context wasn't found in Current Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
}

suspend_source_webhook() {
  echo "Suspending Webhooks for Tyk Operator in the Kubernetes Context $(get_kubeconfig)"
  kubectl get MutatingWebhookConfiguration tyk-operator-mutating-webhook-configuration -o yaml --context "$current_context" >"$(get_source_webhook_dir)"tyk-operator-mutating-webhook-configuration.yaml
  kubectl get ValidatingWebhookConfiguration tyk-operator-validating-webhook-configuration -o yaml --context "$current_context" >"$(get_source_webhook_dir)"tyk-operator-validating-webhook-configuration.yaml
  kubectl delete MutatingWebhookConfiguration tyk-operator-mutating-webhook-configuration --context "$current_context" >/dev/null
  kubectl delete ValidatingWebhookConfiguration tyk-operator-validating-webhook-configuration --context "$current_context" >/dev/null
}

restore_source_webhook() {
  echo "Restoring Webhooks for Tyk Operator in the Kubernetes Context $(get_kubeconfig)"
  kubectl create -f "$(get_source_webhook_dir)"tyk-operator-mutating-webhook-configuration.yaml --context "$current_context" >/dev/null
  kubectl create -f "$(get_source_webhook_dir)"tyk-operator-validating-webhook-configuration.yaml --context "$current_context" >/dev/null
}

clean_operations() {
  echo "Cleaning up all hidden operation files"
  rm -r $operations_directory
}

clean_backups() {
  echo "Cleaning up all backup files"
  rm -r $backup_directory
}

off_source_operator() {
  suspend_source_webhook
  shutdown_source_operator
}

on_source_operator() {
  restore_source_webhook
  startup_source_operator
}

shutdown_source_operator() {
  echo "Shuting Down Tyk Operator for Kubernetes Context $(get_kubeconfig)"
  operator_replica_count=$(kubectl get deployments tyk-operator-controller-manager -n "$source_operator_namespace" -o jsonpath="{.spec.replicas}" --context "$current_context")
  kubectl scale deployment tyk-operator-controller-manager --replicas 0 -n "$source_operator_namespace" --context "$current_context" >/dev/null
  echo "Tyk Operator is Shutdown (Scaled Down)"
}

startup_source_operator() {
  echo "Starting Up Tyk Operator for Kubernetes Context $(get_kubeconfig)"
  kubectl scale deployment tyk-operator-controller-manager --replicas "$operator_replica_count" -n "$source_operator_namespace" --context "$current_context" >/dev/null
  echo "Tyk Operator is up"
}

invalidate_crds() {
  echo "Removiing the Prevouse Source of Truth for your CRDs"
  invalidate "$(get_api_backup_dir)" "tykapis"
  invalidate "$(get_policy_backup_dir)" "tykpolicies"
}

check_crds_cutover() {
  echo "Checking if the Source of Truth has been invalidated or cutover"

  [ $is_cleanable == 1 ] && check_cutover "$(get_api_backup_dir)" "tykapis"
  [ $is_cleanable == 1 ] && check_cutover "$(get_policy_backup_dir)" "tykpolicies"
}

rollback_crd() {
  echo "Rolling Backing Applied CRDs"
  switch_kubeconfig "$destination_kubeconfig"
  delete_api
  delete_policy
  delete_operatorcontext
  switch_kubeconfig "$source_kubeconfig"
}

invalidate() {
  local crd files

  files=$(ls "$1")

  for file in $files; do
    crd=$(cat "$1"/"$file")
    crd=$(get_k8s_object "${file%%.*}" "$2" "$source_namespace")
    crd=$(prepare_invalidation "$crd")
    apply "$crd"

    echo "Invalidated the Source of Truth for $(friendly_name "$2") $file"

  done
}

check_cutover() {
  local files crd

  files=$(ls "$1")

  for file in $files; do
    crd=$(cat "$1"/"$file")
    crd=$(get_k8s_object "${file%%.*}" "$2" "$source_namespace")

    if [ "$(is_invalid "$crd")" == 1 ]; then
      echo "The $(friendly_name "$2") $file has been invalidated"
    else
      echo "The $(friendly_name "$2") $file has not yet been invalidated, please run the cutover command"
      is_cleanable=0
      return
    fi

  done

  is_cleanable=1
}

friendly_name() {
  case $1 in
  apidefinitions) echo "APIs" ;;
  securitypolicies) echo "Policies" ;;
  apidescriptions) echo "API Descriptions" ;;
  operatorcontexts) echo "Operator Contexts" ;;
  portalapicatalogues) echo "Portal Catalogues" ;;
  portalconfigs) echo "Portal Configs" ;;
  subgraphs) echo "Sub Graphs" ;;
  supergraphs) echo "Super Graphs" ;;
  *) echo "$1" ;;
  esac
}

apply() {
  echo "$crd" | kubectl apply -f - -n "$source_namespace" --context "$current_context" >/dev/null
}

get_k8s_object() {
  kubectl get "${2}" "${1}" -n "${3}" -o yaml --context "$current_context"
}

delete_k8s_object() {
  kubectl delete "${2}" "${1}" -n "${3}" --context "$current_context" >/dev/null
}

store() {
  echo "$1" >"$2"
}

prepare() {
  local crd=$1
  crd=$(echo "$crd" | yq "del(.metadata.annotations, .metadata.creationTimestamp, .metadata.finalizers[], .metadata.generation, .metadata.namespace, .metadata.resourceVersion, .metadata.uid, .spec.contextRef, .status)" -)
  crd=$(echo "$crd" | yq '.spec.contextRef.name = '\""$operatorcontext"\"', .spec.contextRef.namespace = '\""$operatorcontext_namespace"\" -)
  echo "$crd"
}

prepare_invalidation() {
  local crd=$1
  crd=$(echo "$crd" | yq "del(.metadata.finalizers[], .spec.contextRef)" -)
  echo "$crd"
}

is_invalid() {
  local finalization_check context_check crd=$1

  finalization_check=$(echo "$crd" | yq '.metadata | has("finalizers")' -)
  context_check=$(echo "$crd" | yq '.spec | has("contextRef")' -)

  if [[ "$finalization_check" == "true" || "$context_check" == "true" ]]; then
    echo 0
  else
    echo 1
  fi
}

indemnify_api() {
  local api_id crd=$1
  api_id=$(echo "$crd" | yq '.status.api_id' -)
  crd=$(echo "$crd" | yq '.spec.api_id = '\""$api_id"\" -)
  echo "$crd"
}

indemnify_policy() {
  local pol_id crd=$1
  pol_id=$(echo "$crd" | yq '.spec._id' -)
  crd=$(echo "$crd" | yq '.spec.id = '\""$pol_id"\" -)
  crd=$(echo "$crd" | yq "del(.spec._id)" -)
  echo "$crd"
}

source_prerequisites() {
  check_source_kubeconfigs "$2"
  validate_source_context "$1" "$3"
}

dependencies() {
  local version

  if ! version=$(kubectl version 2>&1); then
    echo "Kubectl Is not Installed on the Machine. Its required to run the Migration Tooling. More information at https://kubernetes.io/docs/tasks/tools/#kubectl" >&2
    echo "Aborting Operation"
    exit 1
  fi

  if ! version=$(yq -V 2>&1); then
    echo "yq Is not Installed on the Machine. Its required to run the Migration Tooling. More information at https://github.com/mikefarah/yq" >&2
    echo "Aborting Operation"
    exit 1
  fi

  unset "$version"
  echo "The Required Dependecies are Available. Begin Process..."
}

# prerequisites "$n" "$k1" "$k2" "$o1" "$o2"

prerequisites() {
  check_kubeconfigs "$2" "$3"
  validate_source_context "$1" "$4"
  validate_destination_context "$5"
}

check_kubeconfigs() {
  echo "Validating Kube Configs..."

  check_source_kubeconfigs "$1"
  check_destination_kubeconfigs "$2"

  switch_kubeconfig "$source_kubeconfig"
}

check_destination_kubeconfigs() {
  if [ "$(check_kubeconfig "$1")" == 1 ]; then
    destination_kubeconfig=$1
    echo "Destination Kube Config $1 exists"
  else
    echo "Your Destination Kube Config $1 doesn't exist"
  fi
}

check_source_kubeconfigs() {
  if [ "$(check_kubeconfig "$1")" == 1 ]; then
    source_kubeconfig=$1
    echo "Source Kube Config $1 exists"
  else
    echo "Your Source Kube Config $1 doesn't exist"
  fi
}

switch_kubeconfig() {
  # kubectl config use-context "$1" >/dev/null
  current_context="$1"
}

get_kubeconfig() {
  # kubectl config current-context
  echo "$current_context"
}

check_kubeconfig() {
  for config in $(kubectl config get-contexts -o name); do
    # echo "The Kube Config for $config"
    if [ "$1" == "$config" ]; then
      echo 1
      return
    fi
  done
  echo 0
}

# migrate "$n" "$k1" "$k2" "$o1" "$o2"

migrate() {
  dependencies
  echo "Migrating CRDs"

  prerequisites "$1" "$2" "$3" "$4" "$5"

  if [[ $source_operator_namespace != "" && $destination_operator_namespace != "" && $operatorcontext_namespace != "" && $source_kubeconfig != "" && $destination_kubeconfig != "" ]]; then

    scan_namespace

    if [ "$(are_crds_available)" ]; then
      echo "Begin Migration"

      backup_namespace
      migrate_namespace
      report_migration
    else
      echo "No CRDs in the Source Namespace $source_namespace to migrate"
    fi

  else
    echo "Aborting Operation"
  fi
}

cleanup() {
  dependencies
  echo "Cleaning Up CRDs"

  source_prerequisites "$1" "$2" "$3"

  if [[ "$source_kubeconfig" != "" && "$source_namespace" != "" && "$source_operator_namespace" != "" ]]; then

    scan_namespace

    if [ "$(are_crds_available)" ]; then
      echo "Begin Clean Up"

      clean_namespace "$4"
      # clean_operations
      # clean_backups

      report_cleanup
    else
      echo "No CRDs in the Source Namespace $source_namespace to clean up"
    fi

  else
    echo "Aborting Operation"
  fi
}

cutover() {
  dependencies
  echo "Cutting Over Source of Truth away from Source Kubernetes Context"

  source_prerequisites "$1" "$2"

  if [[ "$source_kubeconfig" != "" && "$source_namespace" != "" && "$source_operator_namespace" != "" ]]; then
    # on_source_operator
    invalidate_crds
    # off_source_operator
  else
    echo "Aborting Operation"
  fi

  # startup_source_operator
}

rollback() {
  dependencies
  echo "The Rollback Command is yet to be Implemented"
}

startup-operator() {
  dependencies
  echo "The Startup Operator is yet to be Implemented"
}

# cleanup "$n" "$s"
# cleanup "$n" "$k1" "$o1" "$b"

startup_operator_usage() {
  cat <<EOF
Command:
statup-operator (Not Yet Implemented)

Description:
The statup-operator command is a Utility Command used to restore your Tyk Operator to the Right State in the situation where the Migration doesn't complete successfully

Usage: 
crd-migration statup-operator [ -s SOURCE_KUBECONFIG ]

Flags:
Below are the available flags

  -k : KUBECONFIG ........... The Name of the KubeConfig for the Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  
EOF
}

rollback_usage() {
  cat <<EOF

Command:
rollback (Shared Dashboard) - Not Yet Implemented

Description:
The rollback command is used to clean up the last migration attempt and restore your CRDs to the last known state.

Usage: 
crd-migration rollback -n NAMESPACE [ -k SOURCE_KUBECONFIG DESTINATION_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_KUBECONFIG ] [ -b ]

Flags:
Below are the available flags

  -n : NAMESPACE ................... The Namespace in the Source Kubernetes Cluster that Contains the CRDs you want to Roll Back
  -k : SOURCE_KUBECONFIG ........... The Name of the KubeConfig Context for the Kubernetes Cluster to Roll Back. For example -k context. The Current KubeConfig Context will be consider if not specified
  -o : OPERATOR_CONTEXT ............ The Name of the Tyk Operator Context that should be consider while Rolling Back. For example -o operator-context. If not specified, all Tyk's CRDs will be considered for cleanup.
  -b : BACKUP ...................... Flag used to only Roll Back CRDs that are Backed Up. The defualt directory is considered if no Directory is specified.
  
EOF
}

cleanup_usage() {
  cat <<EOF

Command:
cleanup (Shared and Isolated Dashboard)

Description:
The cleanup command is used to delete CRDs from a namespace. This command can be executed after a successful Migration of your CRDs and if you no longer need the previous CRDs again.

Usage: 
crd-migration cleanup -n NAMESPACE [ -k SOURCE_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_KUBECONFIG ] [ -b ]

Flags:
Below are the available flags

  -n : NAMESPACE ................... The Namespace in the Kubernetes Cluster that Contains the CRDs you want to Clean Up
  -k : KUBECONFIG .................. The Name of the KubeConfig Context for the Kubernetes Cluster to Clean Up. For example -k context. The Current KubeConfig Context will be consider if not specified
  -o : OPERATOR_CONTEXT ............ The Name of the Tyk Operator Context that should be consider while Cleaning Up. For example -o operator-context. If not specified, all Tyk's CRDs will be considered for cleanup.
  -b : BACKUP ...................... Flag used to only Clean Up CRDs that are Backed Up. The defualt directory is considered if no Directory is specified.

Examples:
./crd-migration.sh cleanup -n dev -k tyk2 -o prod -b
./crd-migration.sh cleanup -n dev -k tyk -o dev/dev -b

EOF
}

cutover_usage() {
  cat <<EOF

Command:
cutover (Shared Dashboard) - In Progress

Description:
The cutover is a follow up command executed after the migrate command used to limit the Source of Truth to only the Destination Cluster, invalidating that of the Source Cluster. This command also leaves your Cluster in an intermediate start, and so should be followed up with the Cleanup or Rollback Command.

Usage: 
crd-migration cutover -n NAMESPACE [ -k SOURCE_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_KUBECONFIG ] [ -b ]

Flags:
Below are the available flags

  -n : NAMESPACE ................... The Namespace in the Source Kubernetes Cluster that Contains the CRDs you want to cutover
  -k : KUBECONFIG .................. The Name of the KubeConfig Context for the Kubernetes Cluster to Clean Up. For example -k context. The Current KubeConfig Context will be consider if not specified
  -o : OPERATOR_CONTEXT ............ The Name of the Tyk Operator Context that should be consider while Cutting Over. For example -o operator-context. If not specified, all Tyk's CRDs will be considered for cutover.
  -b : BACKUP ...................... Flag used to only Cut Over CRDs that are Backed Up. The defualt directory is considered if no Directory is specified.
  
EOF
}

migrate_usage() {
  cat <<EOF

Command:
migrate (Shared and Isolated Dashboard)

Description:
The migrate command is used to automate the transfer of CRDs ( APIs, Policies, etc ) from the Source Kubernetes Cluster to the Destinaion Kubernetes Cluster.

Usage: 
crd-migration migrate -n NAMESPACE [ -k SOURCE_KUBECONFIG DESTINATION_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_OPERATOR_CONTEXT <NAMESPACE>/DESTINATION_OPERATOR_CONTEXT ]

Flags:
Below are the available flags

  -n : NAMESPACE ............. The Namespace in the Source Kubernetes Cluster that Contains the CRDs you want to Migrate
  -k : KUBECONFIGs ........... The Names of the KubeConfig Context for the Source and Destination Kubernetes Cluster, delimited by space. For example -k source-context destination-context. You can use - to specify the current KubeConfig Context.
  -o : OPERATOR_CONTEXTs ..... The Names and Namespaces of the Tyk Operator Context for the Source and Destination Kubernetes Cluster of the CRDs, delimited by space. For example -o namespace/source-operator-context1 namespace/destination-operator-context2 or -o source-operator-context1 destination-operator-context2 if you want the script to auto lookup the operator namespace. You can use - as the source operator Context if you don't want it to be taken into account.

Examples:
./crd-migration.sh migrate -n dev -k tyk tyk2 -o dev prod
./crd-migration.sh migrate -n dev -k tyk tyk2 -o dev/dev tyk/prod

EOF
}

command_usage() {
  cat <<EOF

CRD Migration Tooling (crd-migration)

Description:
This Command Script is for automating the migration of CRDs across Kubernetes Clusters, eliminating human error while offering visibility and control over the migration process.

Usage: 
crd-migration COMMAND -flags [OPTIONs]*
  
Cmmands:
 Below are the available commands:

  migrate .......................... The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  cleanup .......................... The Name of the KubeConfig for the Destination Kubernetes Cluster
  cutover (In Progress) ............ The Name of the KubeConfig for the Source Kubernetes Cluster
  rollback (In Progress) ........... The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs
  operator-startup (In Progress) ... The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs

EOF
}

init_source_namespace() {
  local context

  context=$(kubectl config current-context)
  if [[ -z $context ]]; then
    echo "A Source KubeConfig was not specified with the -s flag, and we couldn't use the Current KubeConfig as the Source"
    $1
    exit 1
  fi
  echo "$context"
}

get_next_arg() {
  if [[ $arg_count != "-\w" ]]; then
    arg=$1
    shift
    arg_count=$((arg_count + 1))
  fi
  echo "$arg"
}

execute() {
  if result=$(kubectl $1 --context "$current_context" 2>&1); then
    stdout=$result
    echo "$stdout"
  else
    rc=$?
    stderr=$result
    # printf "failed command\n $stderr\n"
    echo "rc $rc"
    echo "rc $stderr"
  fi
}

start() {
  local b a="tykapise"
  b="tyk"

  execute "get nodes"
  execute "get ${a} -n ${b} -o=custom-columns='name:.metadata.name,context-name:.spec.contextRef.name,context-namespace:.spec.contextRef.namespace'"
}

# scan_crds
# start
# exit

action="$1"
shift

i=2
length=$#

while (("$i" <= $((length + 1)))); do
  case $1 in
  -b)
    b="-"
    shift
    i=$((i + 1))
    if ! [[ $1 == "" || $1 =~ -[a-zA-Z]{1}$ ]]; then
      b=$1
      shift
      i=$((i + 1))
    fi
    ;;
  -n)
    shift
    i=$((i + 1))
    if ! [[ $1 == "" || $1 =~ -[a-zA-Z]{1}$ ]]; then
      n=$1
      shift
      i=$((i + 1))
    fi
    ;;
  -k)
    shift
    i=$((i + 1))
    if ! [[ $1 == "" || $1 =~ -[a-zA-Z]{1}$ ]]; then
      k1=$1
      shift
      i=$((i + 1))
    fi
    if ! [[ $1 == "" || $1 =~ -[a-zA-Z]{1}$ ]]; then
      k2=$1
      shift
      i=$((i + 1))
    fi
    ;;
  -o)
    shift
    i=$((i + 1))
    if ! [[ $1 == "" || $1 =~ -[a-zA-Z]{1}$ ]]; then
      o1=$1
      shift
      i=$((i + 1))
    fi
    if ! [[ $1 == "" || $1 =~ -[a-zA-Z]{1}$ ]]; then
      o2=$1
      shift
      i=$((i + 1))
    fi
    ;;
  *)
    i=$((i + 1))
    shift
    ;;
  esac
done

case $action in
migrate)
  if [[ -z $n ]]; then
    echo "Ensure to use the -n flag to specify the namespace that contains the CRDs"
    migrate_usage
    exit 1
  fi
  if [[ -z $k1 ]]; then
    echo "Ensure to use the -n flag to specify the namespace that contains the CRDs"
    migrate_usage
    exit 1
  fi
  if [[ -z $k2 ]]; then
    echo "Ensure to use the -d flag to specify the Destination KubeConfig"
    migrate_usage
    exit 1
  fi
  if [[ -z $o1 ]]; then
    echo "Ensure to use the -o flag to specify the Operator Context in the Destination Cluster"
    migrate_usage
    exit 1
  fi
  if [[ -z $o2 ]]; then
    echo "Ensure to use the -o flag to specify the Operator Context in the Destination Cluster"
    migrate_usage
    exit 1
  fi

  if [[ $k1 == "-" ]]; then
    k1=$(init_source_namespace "migrate_usage")
  fi
  if [[ $k2 == "-" ]]; then
    k2=$(init_source_namespace "migrate_usage")
  fi

  migrate "$n" "$k1" "$k2" "$o1" "$o2"
  ;;
cutover)
  if [[ -z $n ]]; then
    echo "Ensure to use the -n flag to specify the namespace that contains the CRDs"
    cutover_usage
    exit 1
  fi
  if [[ -z $s ]]; then
    s=$(init_source_namespace "cutover_usage")
  fi
  cutover "$n" "$k1" "$o1" "$b"
  ;;
cleanup)
  if [[ -z $n ]]; then
    echo "Ensure to use the -n flag to specify the namespace that contains the CRDs"
    cleanup_usage
    exit 1
  fi

  if [[ -z $k1 ]]; then
    k1=$(init_source_namespace "migrate_usage")
  fi
  if [[ -z $o1 ]]; then
    o1="-"
  fi
  cleanup "$n" "$k1" "$o1" "$b"
  ;;
rollback)
  if [[ -z $n ]]; then
    echo "Ensure to use the -n flag to specify the namespace that contains the CRDs"
    rollback_usage
    exit 1
  fi
  if [[ -z $s ]]; then
    s=$(init_source_namespace "rollback_usage")
  fi
  if [[ -z $d ]]; then
    echo "Ensure to use the -d flag to specify the Destination KubeConfig"
    rollback_usage
    exit 1
  fi
  rollback "$n" "$s" "$d"
  ;;
startup-operator)
  if [[ -z $s ]]; then
    s=$(init_source_namespace "startup_operator_usage")
  fi
  startup-operator "$s"
  ;;
*)
  echo "The command $action doesn't is available. Please ensure to specify a command as the first argument"
  command_usage
  ;;
esac

# ./crd-migration.sh migrate -n dev -k tyk tyk2 -o dev prod
# ./crd-migration.sh cleanup -n dev -k tyk2 -o prod -b
# ./crd-migration.sh cleanup -n dev -k tyk -o dev -b

# echo "Action $action"
# echo "Namespace $n"
# echo "Kube Configs $k1 and $k2"
# echo "Operator Context $o1 and $o2"
# o="$(echo "$o2" | awk -F / '{print $1}')"
# on="$(echo "$o2" | awk -F / '{print $2}')"
# echo "Destination Operator Context $o and Namespace $on"
# echo "Backup Directory $b"
