#!/bin/bash

is_crds_available=0
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

backup() {
  i=0
  for name in $(kubectl get "$1" -n "$source_namespace" -o name); do
    name="${name##*/}"
    kubectl get "${1}" "${name}" -n "$source_namespace" -o yaml >"${2}"/"${name}".yaml
    i=$((i + 1))
  done
  echo $i
}

get_source_webhook_dir() {
  dir="$operations_directory"source/
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_destination_webhook_dir() {
  dir="$operations_directory"destination/
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_api_backup_dir() {
  dir="$backup_directory""$source_namespace"/api
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_api_live_dir() {
  dir="$live_directory""$source_namespace"/api
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_policy_backup_dir() {
  dir="$backup_directory""$source_namespace"/policy
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_policy_live_dir() {
  dir="$live_directory""$source_namespace"/policy
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

scan() {
  i=0
  for name in $(kubectl get "$1" -n "$source_namespace" -o name); do
    i=$((i + 1))
  done
  echo $i
}

backup_namespace() {
  echo "Backing Up all CRDs in Namespace"
  backup_policies
  backup_api
}

backup_api() {
  n=$(backup tykapis "$(get_api_backup_dir)")
  echo "Backup $n number of APIs"
}

backup_policies() {
  n=$(backup tykpolicies "$(get_policy_backup_dir)")
  echo "Backup $n number of Policies"
}

scan_api() {
  scan tykapis
}

scan_policies() {
  scan tykpolicies
}

scan_namespace() {
  echo "Scanning the $source_namespace Namespace of the $(get_kubeconfig) Kubernetes Context for CRDs...."

  apis=$(scan_api)
  echo "Discover $apis number of APIs"

  policies=$(scan_policies)
  echo "Discover $policies number of Policies"

  is_crds_available=$((apis != 0 || policies != 0))
}

find_k8s_object() {
  k8s_object=""
  while read -r line; do
    if [[ $line == *"$2"* ]]; then
      k8s_object="$(echo "$line" | awk '{print $2}')"
      echo "$k8s_object"
      return
    fi
  done <<<"$(kubectl get "$1" -A -o=custom-columns='name:.metadata.name,namespace:.metadata.namespace')"
  echo "$k8s_object"
}

find_source_operator() {
  source_operator_namespace=$(find_k8s_object "deployments" "tyk-operator-controller-manager")
  if [ "$source_operator_namespace" == "" ]; then
    echo "No Operator found in the Source Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
  echo "Validated the existence of an Operator in the Source Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
}

find_destination_operator() {
  destination_operator_namespace=$(find_k8s_object "deployments" "tyk-operator-controller-manager")
  if [ "$destination_operator_namespace" == "" ]; then
    echo "No Operator found in the Destination Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
  echo "Validated the existence of an Operator in the Destination Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
}

validate_source_namespace() {
  namespaceStatus=$(kubectl get ns "$1" -o yaml 2>/dev/null | yq .status.phase -r)
  if [ "$namespaceStatus" == "Active" ]; then
    source_namespace=$1
    echo "The Source Namespace $source_namespace is present in Kubernetes Context $(get_kubeconfig)"
  else
    echo "The Source Namespace $1 doesn't exist in Kubernetes Context $(get_kubeconfig)"
  fi
}

validate_destination_namespace() {
  namespaceStatus=$(kubectl get ns "$source_namespace" -o yaml 2>/dev/null | yq .status.phase -r)
  if [ "$namespaceStatus" == "Active" ]; then
    echo "Source Namespace $source_namespace is also present in Kubernetes Context $(get_kubeconfig)"
  else
    kubectl create ns "$source_namespace" >/dev/null
    echo "Created Source Namespace $source_namespace in Kubernetes Context $(get_kubeconfig)"
  fi
}

validate_destination_context() {
  switch_kubeconfig "$destination_kubeconfig"
  find_operatorcontext "$1"
  find_destination_operator
  validate_destination_namespace
  switch_kubeconfig "$source_kubeconfig"
}

validate_source_context() {
  if [ "$source_kubeconfig" != "" ]; then
    switch_kubeconfig "$source_kubeconfig"
    validate_source_namespace "$1"
    find_source_operator
  fi
}

find_operatorcontext() {
  namespace=$(find_k8s_object "operatorcontext" "$1")
  if [ "$namespace" != "" ]; then
    operatorcontext=$1
    operatorcontext_namespace=$namespace
    echo "Validated the existence of the Operator Context $operatorcontext in the Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  else
    echo "The Operator Context $operatorcontext wasn't found in Current Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
}

suspend_source_webhook() {
  echo "Suspending Webhooks for Tyk Operator in the Kubernetes Context $(get_kubeconfig)"
  kubectl get MutatingWebhookConfiguration tyk-operator-mutating-webhook-configuration -o yaml >"$(get_source_webhook_dir)"tyk-operator-mutating-webhook-configuration.yaml
  kubectl get ValidatingWebhookConfiguration tyk-operator-validating-webhook-configuration -o yaml >"$(get_source_webhook_dir)"tyk-operator-validating-webhook-configuration.yaml
  kubectl delete MutatingWebhookConfiguration tyk-operator-mutating-webhook-configuration >/dev/null
  kubectl delete ValidatingWebhookConfiguration tyk-operator-validating-webhook-configuration >/dev/null
}

restore_source_webhook() {
  echo "Restoring Webhooks for Tyk Operator in the Kubernetes Context $(get_kubeconfig)"
  kubectl create -f "$(get_source_webhook_dir)"tyk-operator-mutating-webhook-configuration.yaml >/dev/null
  kubectl create -f "$(get_source_webhook_dir)"tyk-operator-validating-webhook-configuration.yaml >/dev/null
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
  operator_replica_count=$(kubectl get deployments tyk-operator-controller-manager -n tyk -o jsonpath="{.spec.replicas}")
  kubectl scale deployment tyk-operator-controller-manager --replicas 0 -n "$source_operator_namespace" >/dev/null
  echo "Tyk Operator is Shutdown (Scaled Down)"
}

startup_source_operator() {
  echo "Starting Up Tyk Operator for Kubernetes Context $(get_kubeconfig)"
  kubectl scale deployment tyk-operator-controller-manager --replicas "$operator_replica_count" -n "$source_operator_namespace" >/dev/null
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

migrate_crd() {
  echo "Migrating CRDs from Backup"
  switch_kubeconfig "$destination_kubeconfig"
  restore_api
  restore_policy
  switch_kubeconfig "$source_kubeconfig"
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

clean() {
  files=$(ls "$1")

  for file in $files; do
    crd=$(cat "$1"/"$file")
    delete_k8s_object "${file%%.*}" "$2" "$source_namespace"
    echo "Deleted the $(friendly_name "$2") $file from the $source_namespace Namespace"
  done

  is_cleanable=1
}

clean_crds() {
  echo "Cleaning Up Backed up CRDs"
  clean "$(get_policy_backup_dir)" "tykpolicies"
  clean "$(get_api_backup_dir)" "tykapis"
}

friendly_name() {
  if [ "$1" == "tykapis" ]; then
    echo "API"
  fi
  if [ "$1" == "tykpolicies" ]; then
    echo "Policy"
  fi
}

restore() {
  files=$(ls "$1")

  for file in $files; do
    crd=$(cat "$1"/"$file")

    if [ "$3" == "API" ]; then
      crd=$(indemnify_api "$crd")
    fi
    if [ "$3" == "Policy" ]; then
      crd=$(indemnify_policy "$crd")
    fi

    crd=$(prepare "$crd")
    store "$crd" "$2/$file"
    apply "$crd"

    echo "Restored $3 $file"
  done
}

restore_api() {
  restore "$(get_api_backup_dir)" "$(get_api_live_dir)" "API"
}

restore_policy() {
  restore "$(get_policy_backup_dir)" "$(get_policy_live_dir)" "Policy"
}

apply() {
  echo "$crd" | kubectl apply -f - -n "$source_namespace" >/dev/null
}

get_k8s_object() {
  kubectl get "${2}" "${1}" -n "${3}" -o yaml
}

delete_k8s_object() {
  kubectl delete "${2}" "${1}" -n "${3}" >/dev/null
}

store() {
  echo "$1" >"$2"
}

prepare() {
  crd=$1
  crd=$(echo "$crd" | yq "del(.metadata.annotations, .metadata.creationTimestamp, .metadata.finalizers[], .metadata.generation, .metadata.namespace, .metadata.resourceVersion, .metadata.uid, .spec.contextRef, .status)" -)
  crd=$(echo "$crd" | yq '.spec.contextRef.name = '\""$operatorcontext"\"', .spec.contextRef.namespace = '\""$operatorcontext_namespace"\" -)
  echo "$crd"
}

prepare_invalidation() {
  crd=$1
  crd=$(echo "$crd" | yq "del(.metadata.finalizers[], .spec.contextRef)" -)
  echo "$crd"
}

is_invalid() {
  crd=$1

  finalization_check=$(echo "$crd" | yq '.metadata | has("finalizers")' -)
  context_check=$(echo "$crd" | yq '.spec | has("contextRef")' -)

  if [[ "$finalization_check" == "true" || "$context_check" == "true" ]]; then
    echo 0
  else
    echo 1
  fi
}

indemnify_api() {
  crd=$1
  api_id=$(echo "$crd" | yq '.status.api_id' -)
  crd=$(echo "$crd" | yq '.spec.api_id = '\""$api_id"\" -)
  echo "$crd"
}

indemnify_policy() {
  crd=$1
  pol_id=$(echo "$crd" | yq '.spec._id' -)
  crd=$(echo "$crd" | yq '.spec.id = '\""$pol_id"\" -)
  crd=$(echo "$crd" | yq "del(.spec._id)" -)
  echo "$crd"
}

source_prerequisites() {
  check_source_kubeconfigs "$2"
  validate_source_context "$1"
}

prerequisites() {
  check_kubeconfigs "$2" "$3"
  validate_source_context "$1"
  validate_destination_context "$4"
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
    echo "Validated the Destination Kube Config $1"
  else
    echo "Your Destination Kube Config $1 doesn't exist"
  fi
}

check_source_kubeconfigs() {
  if [ "$(check_kubeconfig "$1")" == 1 ]; then
    source_kubeconfig=$1
    echo "Validated the Source Kube Config $1"
  else
    echo "Your Source Kube Config $1 doesn't exist"
  fi
}

switch_kubeconfig() {
  kubectl config use-context "$1" >/dev/null
}

get_kubeconfig() {
  kubectl config current-context
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

migrate() {

  prerequisites "$1" "$2" "$3" "$4"

  if [[ $source_operator_namespace != "" && $destination_operator_namespace != "" && $operatorcontext_namespace != "" && $source_kubeconfig != "" && $destination_kubeconfig != "" ]]; then

    scan_namespace

    if [ $is_crds_available == 1 ]
    then
      echo "Migration Starts"

      off_source_operator
      backup_namespace
      migrate_crd
    else
      echo "No CRDs in the Source Namespace $source_namespace to migrate"
    fi

    
    # on_source_operator
  else
    echo "Aborting Operation"
  fi
}

cutover() {
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
  echo "The Rollback Command is yet to be Implemented"
}

startup-operator() {
  echo "The Startup Operator is yet to be Implemented"
}

cleanup() {
  echo "Cleaning Up Invalid Source of Truth in the Source Kubernetes Context"

  source_prerequisites "$1" "$2"

  if [[ "$source_kubeconfig" != "" && "$source_namespace" != "" && "$source_operator_namespace" != "" ]]; then
    # on_source_operator
    check_crds_cutover
    if [ $is_cleanable == 1 ]; then
      clean_crds
      on_source_operator
      clean_operations
      clean_backups
    fi

  else
    echo "Aborting Operation"
  fi

  # on_source_operator
}

process_commmand() {
  echo "Process Commands"
}

process_migrate() {
  echo "Migration Begin"
}

startup_operator_usage() {
  cat <<EOF
Command:
statup-operator (Not Yet Implemented)

Description:
The statup-operator command is a Utility Command used to restore your Tyk Operator to the Right State in the situation where the Migration doesn't complete successfully

Usage: 
crd-migration statup-operator -n NAMESPACE [ -s SOURCE_KUBECONFIG ]

Flags:
Below are the available flags

  -s : SOURCE_KUBECONFIG ........... The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  
EOF
}

rollback_usage() {
  cat <<EOF

Command:
rollback (Not Yet Implemented)

Description:
The rollback command is used to clean up the last migration attempt and restore your CRDs to the last known state.

Usage: 
crd-migration rollback -n NAMESPACE [ -s SOURCE_KUBECONFIG ]

Flags:
Below are the available flags

  -n : NAMESPACE ................... The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  -s : SOURCE_KUBECONFIG ........... The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  -d : DESTINATION_KUBECONFIG ...... The Name of the KubeConfig for the Destination Kubernetes Cluster
  
EOF
}

cleanup_usage() {
  cat <<EOF

Command:
cleanup

Description:
The cleanup is a follow up command executed after the cutover command used to restore the Source Cluster to the Previous state and Clean up the migrated CRDs, Backup and Operation Files. After this command is executed, you can't rollback.

Usage: 
crd-migration cleanup -n NAMESPACE [ -s SOURCE_KUBECONFIG ]

Flags:
Below are the available flags

  -n : NAMESPACE ................... The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  -s : SOURCE_KUBECONFIG ........... The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  
EOF
}

cutover_usage() {
  cat <<EOF

Command:
cutover

Description:
The cutover is a follow up command executed after the migrate command used to limit the Source of Truth to only the Destination Cluster, invalidating that of the Source Cluster. This command also leaves your Cluster in an intermediate start, and so should be followed up with the Cleanup or Rollback Command.

Usage: 
crd-migration cutover -n NAMESPACE [ -s SOURCE_KUBECONFIG ]

Flags:
Below are the available flags

  -n : NAMESPACE ................... The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  -s : SOURCE_KUBECONFIG ........... The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  
EOF
}

migrate_usage() {
  cat <<EOF

Command:
migrate

Description:
The migrate command is used to automate the transfer of CRDs ( APIs, Policies, etc ) from the Source Kubernetes Cluster to the Destinaion Kubernetes Cluster.

Usage: 
crd-migration migrate -n NAMESPACE [ -s SOURCE_KUBECONFIG ] -d DESTINATION_KUBECONFIG -o OPERATOR_CONTEXT

Flags:
Below are the available flags

  -n : NAMESPACE ................... The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  -s : SOURCE_KUBECONFIG ........... The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  -d : DESTINATION_KUBECONFIG ...... The Name of the KubeConfig for the Destination Kubernetes Cluster
  -o : OPERATOR_CONTEXT ............ The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs

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

  migrate ................ The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  cutover ................ The Name of the KubeConfig for the Source Kubernetes Cluster
  cleanup ................ The Name of the KubeConfig for the Destination Kubernetes Cluster
  rollback ............... The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs
  operator-startup ....... The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs

EOF
}

init_source_namespace() {
  context=$(kubectl config current-context)
  if [[ -z $context ]]; then
    echo "A Source KubeConfig was not specified with the -s flag, and we couldn't use the Current KubeConfig as the Source"
    $1
    exit 1
  fi
  echo "$context"
}

# on_source_operator
# clean_backups
# clean_operations
# exit 0

action="$1"
shift 1

while getopts n:s:d:o: opt; do
  case $opt in
  n) n=$OPTARG ;;
  s) s=$OPTARG ;;
  d) d=$OPTARG ;;
  o) o=$OPTARG ;;
  *) ;;
  esac
done

case $action in
migrate)
  if [[ -z $n ]]; then
    echo "Ensure to use the -n flag to specify the namespace that contains the CRDs"
    migrate_usage
    exit 1
  fi
  if [[ -z $s ]]; then
    s=$(init_source_namespace "migrate_usage")
  fi
  if [[ -z $d ]]; then
    echo "Ensure to use the -d flag to specify the Destination KubeConfig"
    migrate_usage
    exit 1
  fi
  if [[ -z $o ]]; then
    echo "Ensure to use the -o flag to specify the Operator Context in the Destination Cluster"
    migrate_usage
    exit 1
  fi
  migrate "$n" "$s" "$d" "$o"
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
  cutover "$n" "$s"
  ;;
cleanup)
  if [[ -z $n ]]; then
    echo "Ensure to use the -n flag to specify the namespace that contains the CRDs"
    cleanup_usage
    exit 1
  fi
  if [[ -z $s ]]; then
    s=$(init_source_namespace "cleanup_usage")
  fi
  cleanup "$n" "$s"
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

# migrate dev tyk tyk2 prod
# cutover dev tyk
# cleanup dev tyk
