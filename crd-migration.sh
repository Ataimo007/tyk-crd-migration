#!/usr/bin/env bash

operatorcontext=""
source_operator_namespace=""
destination_operator_namespace=""
operatorcontext_namespace=""
source_kubeconfig=""
destination_kubeconfig=""
source_namespace=""
backup_directory="./backup/"
live_directory="./live/"
source_operatorcontext=""
source_operatorcontext_namespace=""
masked_prefix="tyk-crd-migration-masked-operator-context-"

declare -A scanned_crds
declare -A backedup_crds
declare -A migrated_crds
declare -A cleanedup_crds
current_context=""

get_backup_dir() {
  local dir
  dir=$(get_backup_dir_only)

  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_backup_dir_only() {
  local dir

  if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
    dir="$backup_directory""$source_namespace"/"$source_operatorcontext"/
  else
    dir="$backup_directory""$source_namespace"/
  fi
  
  echo "$dir"
}

get_live_dir() {
  local dir
  dir=$(get_live_dir_only)

  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_live_dir_only() {
  local dir

  if [[ $source_operatorcontext != "" && $source_operatorcontext_namespace != "" ]]; then
    dir="$live_directory""$source_namespace"/"$source_operatorcontext"/
  else
    dir="$live_directory""$source_namespace"/
  fi

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

      if [[ $context_name == "$source_operatorcontext" && $context_namespace == "$source_operatorcontext_namespace" ]] || [[ $1 == "operatorcontexts" ]] || [[ $1 == "portalconfigs" ]]; then
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

      if [[ $3 != "portalconfigs" ]]; then
        if ! [[ $source_operatorcontext == "$crd_context_name" && $source_operatorcontext_namespace == "$crd_context_namespace" ]]; then
          continue
        fi
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

      if [[ $context_name == "$source_operatorcontext" && $context_namespace == "$source_operatorcontext_namespace" ]] || [[ $1 == "operatorcontexts" ]] || [[ $1 == "portalconfigs" ]]; then
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
  local crd
  switch_kubeconfig "$destination_kubeconfig"

  for crd in portalapicatalogues apidescriptions securitypolicies apidefinitions subgraphs supergraphs portalconfigs; do
    echo "Migrating $(friendly_name "$crd")"
    restore "$(get_crd_backup_dir "$crd")" "$(get_crd_live_dir "$crd")" "$crd"
    echo "Migrated ${migrated_crds[$crd]} $(friendly_name "$crd")"
  done

  switch_kubeconfig "$source_kubeconfig"
}

cleanup_crds() {
  local crdname
  for crdname in portalapicatalogues apidescriptions securitypolicies apidefinitions subgraphs supergraphs portalconfigs; do
    if [[ ${scanned_crds[$crdname]} -gt 0 ]]; then
      clean_crds "$crdname" "$1"
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

    if [ "$1" != "" ]; then
      validate_source_namespace "$1"
    fi
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
  echo "The Required Dependencies are Available. Begin Process..."
}

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
  current_context="$1"
}

get_kubeconfig() {
  echo "$current_context"
}

check_kubeconfig() {
  for config in $(kubectl config get-contexts -o name); do
    if [ "$1" == "$config" ]; then
      echo 1
      return
    fi
  done
  echo 0
}

migrate() {
  dependencies
  echo "Migrating CRDs"

  prerequisites "$1" "$2" "$3" "$4" "$5"

  if [[ $source_operator_namespace != "" && $destination_operator_namespace != "" && $operatorcontext_namespace != "" && $source_kubeconfig != "" && $destination_kubeconfig != "" ]]; then

    scan_namespace

    if [ "$(are_crds_available)" ]; then
      echo "Begin Migration"

      clean_previous_dir
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

clean_previous_dir() {
  [ -d "$(get_backup_dir_only)" ] && rm -r "$(get_backup_dir_only)" &>/dev/null
  [ -d "$(get_backup_dir_only)" ] && rm -d "$(get_backup_dir_only)" &>/dev/null

  [ -d "$(get_live_dir_only)" ] && rm -r "$(get_live_dir_only)" &>/dev/null
  [ -d "$(get_live_dir_only)" ] && rm -d "$(get_live_dir_only)" &>/dev/null
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
      report_cleanup
    else
      echo "No CRDs in the Source Namespace $source_namespace to clean up"
    fi

  else
    echo "Aborting Operation"
  fi
}

mask() {
  dependencies
  source_prerequisites "" "$1" "$2"

  if [[ "$source_kubeconfig" != "" && "$source_operator_namespace" != "" ]]; then
    echo "Begin Operator Context Masking"
    mask_operator_context "$3" "$4"

    echo "Operator Context Masking Complete"
  fi
}

unmask() {
  dependencies
  source_prerequisites "" "$1" "$2"

  if [[ "$source_kubeconfig" != "" && "$source_operator_namespace" != "" ]]; then
    echo "Begin Unmasking the Operator Context"
    unmask_operator_context
  fi
}

unmask_operator_context() {
  if masked=$(kubectl get configmap "$(get_masked_name "$source_operatorcontext" "$source_operatorcontext_namespace")" -n "$source_operatorcontext_namespace" -o yaml --context "$current_context" 2>&1); then
    echo "The Operator Context is Masked, Unmasking...."
    unregister_mask

    echo "Operator Context Unmasking Complete"
  else
    echo "Operator Context haven't been Masked. Aborting Operation"
  fi

  unset "$masked"
}

mask_operator_context() {
  if masked=$(kubectl get configmap "$(get_masked_name "$source_operatorcontext" "$source_operatorcontext_namespace")" -n "$source_operatorcontext_namespace" -o yaml --context "$current_context" 2>&1); then
    echo "This Operator Context is Masked, Update Mask...."
    mask_context "$1" "$2" >/dev/null
    echo "Updated Operator Context Mask"
  else
    echo "This Operator Context haven't been Masked, Masking Operator Context"
    register_mask "$1" "$2"
  fi

  unset "$masked"
}

unregister_mask() {
  local dashboard_url

  unmask_context
  echo "Unmasked Operator Context"

  kubectl delete configmap "$(get_masked_name "$source_operatorcontext" "$source_operatorcontext_namespace")" -n "$source_operatorcontext_namespace" --context "$current_context" >/dev/null
  echo "Unregistered Masked Operator"

  if [[ $(kubectl get configmap -A --context "$current_context" | grep $masked_prefix) == "" ]]; then
    echo "No Masked Operator available, Removing API Mask"

    if [[ $(is_operator_mask_applied) == 1 ]]; then
      delete_mask
    fi
  fi
}

register_mask() {
  local dashboard_url

  if [[ $2 == 1 && $(is_operator_mask_applied) == 0 ]]; then
    create_mask
  fi

  if [[ $(is_operator_mask_applied) ]]; then
    is_operator_mask_reachable "$1"

    dashboard_url=$(mask_context "$1" "$2")
    echo "Masked Operator Context"

    kubectl create configmap "$(get_masked_name "$source_operatorcontext" "$source_operatorcontext_namespace")" --from-literal=dashboard_url="$dashboard_url" -n "$source_operatorcontext_namespace" --context "$current_context" >/dev/null
    echo "Registered Masked Operator"
  fi
}

unmask_context() {
  local operator_context
  operator_context=$(kubectl get operatorcontext "$source_operatorcontext" -n "$source_operatorcontext_namespace" -o yaml --context "$current_context")
  dashboard_url=$(kubectl get configmap "$(get_masked_name "$source_operatorcontext" "$source_operatorcontext_namespace")" -n "$source_operatorcontext_namespace" -o=jsonpath='{.data.dashboard_url}' --context "$current_context")
  operator_context=$(echo "$operator_context" | yq '.spec.env.url = '\""$dashboard_url"\" -)
  echo "$operator_context" | kubectl apply -f - -n "$source_operatorcontext_namespace" --context "$current_context" >/dev/null
}

get_masked_name() {
  echo "$masked_prefix$2-$1"
}

mask_context() {
  local operator_context dashboard_url
  operator_context=$(kubectl get operatorcontext "$source_operatorcontext" -n "$source_operatorcontext_namespace" -o yaml --context "$current_context")
  dashboard_url=$(echo "$operator_context" | yq '.spec.env.url' -)

  if [[ $2 ]]; then
    operator_context=$(echo "$operator_context" | yq '.spec.env.url = '\""$1/operator-mask"\" -)
  else
    operator_context=$(echo "$operator_context" | yq '.spec.env.url = '\""$1"\" -)
  fi

  echo "$operator_context" | kubectl apply -f - -n "$source_operatorcontext_namespace" --context "$current_context" >/dev/null
  echo "$dashboard_url"
}

is_operator_mask_applied() {
  local namespace status
  namespace=$(find_k8s_object "apidefinitions" "tyk-crd-migration-operator-mask")

  if [[ $namespace != "" ]]; then
    status=$(kubectl get tykapis tyk-crd-migration-operator-mask -n "$namespace" -o jsonpath="{.status.latestTransaction.status}" --context "$current_context")

    if [[ $status == "Successful" ]]; then
      echo 1
      return
    fi
  fi
  echo 0
}

is_operator_mask_reachable() {
  local response

  if response=$(curl --location "$1/operator-mask" 2>&1); then
    if [[ $response == *"tyk-crd-migration"* && $response == *"mask"* ]]; then
      echo "Mask is publicly accessible and ready to be used by the Operator Context"
      return
    else
      echo "The Operator Mask didn't return a valid Response"
    fi
  else
    echo "The Gateway URL isn't publicly accessible from the Internet, kindly double check if this is intended"
  fi

}

delete_mask() {
  local namespace
  namespace=$(find_k8s_object "apidefinitions" "tyk-crd-migration-operator-mask")
  kubectl delete tykapis tyk-crd-migration-operator-mask -n "$namespace" --context "$current_context" >/dev/null
}

create_mask() {
  kubectl create -f - -n "$source_operatorcontext_namespace" --context "$current_context" &>/dev/null <<EOF
apiVersion: tyk.tyk.io/v1alpha1
kind: ApiDefinition
metadata:
  name: tyk-crd-migration-operator-mask
spec:
  name: "Tyk CRD Migration Operator Mask"
  active: true
  use_keyless: true
  proxy:
    target_url: http://httpbin.org
    listen_path: /operator-mask
    strip_listen_path: true
  version_data:
    default_version: Default
    not_versioned: true
    versions:
      Default:
        name: Default
        use_extended_paths: true
        paths:
          black_list: []
          ignored: []
          white_list: []
        extended_paths:
          ignored:
            - ignore_case: false
              method_actions:
                GET:
                  action: "reply"
                  code: 200
                  data: '{"x-agent": "tyk-crd-migration", "x-action": "mask", "message": "Masking Operator Functionality"}'
                  headers: {"Content-Type": "application/json"}
                POST:
                  action: "reply"
                  code: 200
                  data: '{"x-agent": "tyk-crd-migration", "x-action": "mask", "message": "Masking Operator Functionality"}'
                  headers: {"Content-Type": "application/json"}
                DELETE:
                  action: "reply"
                  code: 200
                  data: '{"x-agent": "tyk-crd-migration", "x-action": "mask", "message": "Masking Operator Functionality"}'
                  headers: {"Content-Type": "application/json"}
                PUT:
                  action: "reply"
                  code: 200
                  data: '{"x-agent": "tyk-crd-migration", "x-action": "mask", "message": "Masking Operator Functionality"}'
                  headers: {"Content-Type": "application/json"}
              path: /*
EOF

  echo "Created API Mask"
}

get_mask() {
  cat <<EOF
apiVersion: tyk.tyk.io/v1alpha1
kind: ApiDefinition
metadata:
  name: tyk-crd-migration-operator-mask
spec:
  name: "Tyk CRD Migration Operator Mask"
  active: true
  use_keyless: true
  proxy:
    target_url: http://httpbin.org
    listen_path: /operator-mask
    strip_listen_path: true
  version_data:
    default_version: Default
    not_versioned: true
    versions:
      Default:
        name: Default
        use_extended_paths: true
        paths:
          black_list: []
          ignored: []
          white_list: []
        extended_paths:
          ignored:
            - ignore_case: false
              method_actions:
                GET:
                  action: "reply"
                  code: 200
                  data: '{"x-agent": "tyk-crd-migration", "x-action": "mask", "message": "Masking Operator Functionality"}'
                  headers: {"Content-Type": "application/json"}
                POST:
                  action: "reply"
                  code: 200
                  data: '{"x-agent": "tyk-crd-migration", "x-action": "mask", "message": "Masking Operator Functionality"}'
                  headers: {"Content-Type": "application/json"}
                DELETE:
                  action: "reply"
                  code: 200
                  data: '{"x-agent": "tyk-crd-migration", "x-action": "mask", "message": "Masking Operator Functionality"}'
                  headers: {"Content-Type": "application/json"}
                PUT:
                  action: "reply"
                  code: 200
                  data: '{"x-agent": "tyk-crd-migration", "x-action": "mask", "message": "Masking Operator Functionality"}'
                  headers: {"Content-Type": "application/json"}
              path: /*
EOF
}

get_mask_usage() {
  cat <<EOF
Command:
get-mask

Description:
The get-mask command is used to retrieve an API Definition CRD for manual creation of an API on Tyk for Masking an Operator Context.  

Usage: 
crd-migration get-mask

Examples:
./crd-migration.sh get-mask

EOF
}

mask_usage() {
  cat <<EOF
Command:
mask

Description:
The mask command is to mask the functionality of the Operator for a specify Operator Context. This is used so you can carry out operations on the CRDs without alerting the Dashboard on reconciliation.

Usage: 
crd-migration mask [ -k SOURCE_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_KUBECONFIG ] [ -u MASK_URL ] [ -t TYK_MASKING ]

Flags:
Below are the available flags

  -k : KUBECONFIG .................. The Name of the KubeConfig for the Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context.
  -o : OPERATOR_CONTEXT ............ The Name of the Tyk Operator Context that should be Masked. For example -o operator-context.
  -u : MASK_URL .................... The URL of an API you want to use to Mask the specified Operator Context. When Tyk Masking is enabled, this should be your Gateway URL.
  -t : TYK_MASKING ................. An indicator flag to consent to the automatic creation of an API on Tyk for Masking the Operator Context.
  
Examples:
./crd-migration.sh mask -k tyk -o tyk-dev -u https://httpbin.org/status/200
./crd-migration.sh mask -k tyk -o tyk-dev -u https://gateway.ataimo.com -t

EOF
}

unmask_usage() {
  cat <<EOF
Command:
unmask

Description:
The unmask command is to remove any available mask registered on an Operator Context. It's usage is followed after the mask Command to re-enable Dashbaord Communication.

Usage: 
crd-migration unmask [ -k SOURCE_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_KUBECONFIG ] [ -g GATEWAY_URL ]

Flags:
Below are the available flags

  -k : KUBECONFIG .................. The Name of the KubeConfig for the Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  -o : OPERATOR_CONTEXT ............ The Name of the Tyk Operator Context that should be Unmasked. For example -o operator-context.
  
Examples:
./crd-migration.sh unmask -k tyk -o tyk-dev

EOF
}

cleanup_usage() {
  cat <<EOF

Command:
cleanup

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

migrate_usage() {
  cat <<EOF

Command:
migrate

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

  migrate .......................... To Migrate CRDs across Kubenetes Clusters
  cleanup .......................... To Clean Up CRDs in a Kubenetes Clusters
  mask ............................. To Mask the Functionality of the Operator for a specify Operator Context
  unmask ........................... To Restore the Operator's Functionality on an Operator Context
  get-mask ......................... To get an API Definition for manual creation of an Operator's Mask on Tyk

EOF
}

init_source_namespace() {
  local context

  context=$(kubectl config current-context)
  if [[ -z $context ]]; then
    echo "A Source KubeConfig was not specified with the -k flag, and we couldn't use the Current KubeConfig as the Source"
    $1
    exit 1
  fi
  echo "$context"
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
  -t)
    t=1
    shift
    i=$((i + 1))
    ;;
  -h)
    h=1
    shift
    i=$((i + 1))
    ;;
  -u)
    shift
    i=$((i + 1))
    if ! [[ $1 == "" || $1 =~ -[a-zA-Z]{1}$ ]]; then
      u=$1
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
  if [[ $h ]]; then
    migrate_usage
    exit
  fi

  if [[ -z $n ]]; then
    echo "Ensure to use the -n flag to specify the namespace that contains the CRDs"
    migrate_usage
    exit 1
  fi
  if [[ -z $k1 ]]; then
    echo "Ensure to use the -k flag to specify the Source Kube Config (first parameter) you are migrating From"
    migrate_usage
    exit 1
  fi
  if [[ -z $k2 ]]; then
    echo "Ensure to use the -k flag to specify the Destination Kube Config (second parameter) you are migrating To"
    migrate_usage
    exit 1
  fi
  if [[ -z $o1 ]]; then
    echo "Ensure to use the -o flag to specify the Source Operator Context (first parameter) in the Source Cluster"
    migrate_usage
    exit 1
  fi
  if [[ -z $o2 ]]; then
    echo "Ensure to use the -o flag to specify the Destination Operator Context (second parameter) in the Destination Cluster"
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
cleanup)
  if [[ $h ]]; then
    cleanup_usage
    exit
  fi

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
mask)
  if [[ $h ]]; then
    mask_usage
    exit
  fi

  if [[ -z $o1 ]]; then
    echo "Ensure to use the -o flag to specify the Operator Context you want to Mask"
    mask_usage
    exit 1
  fi
  if [[ -z $u ]]; then
    echo "Ensure to use the -u flag to specify the URL of your Mask for the specified Operator Context"
    mask_usage
    exit 1
  fi
  if [[ -z $k1 ]]; then
    k1=$(init_source_namespace "mask_usage")
  fi
  if [[ -z $t ]]; then
    t=0
  fi
  mask "$k1" "$o1" "$u" "$t"
  ;;
unmask)
  if [[ $h ]]; then
    unmask_usage
    exit
  fi

  if [[ -z $o1 ]]; then
    echo "Ensure to use the -o flag to specify the Operator Context you want to Mask"
    unmask_usage
    exit 1
  fi
  if [[ -z $k1 ]]; then
    k1=$(init_source_namespace "unmask_usage")
  fi
  unmask "$k1" "$o1"
  ;;
get-mask)
  if [[ $h ]]; then
    get_mask_usage
    exit
  fi

  get_mask
  ;;
*)
  echo "The command $action doesn't is available. Please ensure to specify a command as the first argument"
  command_usage
  ;;
esac

# ./crd-migration.sh migrate -n dev -k tyk tyk2 -o dev prod
# ./crd-migration.sh cleanup -n dev -k tyk2 -o prod -b
# ./crd-migration.sh cleanup -n dev -k tyk -o dev -b
