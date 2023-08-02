#!/bin/bash

is_crds_available=0
is_migratable=0
operatorcontext=""
operator_namespace=""
operatorcontext_namespace=""
source_kubeconfig=""
destination_kubeconfig=""
operator_replica_count=1
source_namespace=""
destination_namespace=""
backup_directory="./backup/"
live_directory="./live/"

backup() {
  i=0
  for name in $(kubectl get "$1" -n "$source_namespace" -o name); do
    name="${name##*/}"
    kubectl get "${1}" "${name}" -n "$source_namespace" -o yaml > "${2}"/"${name}".yaml
    i=$((i+1))
  done
  echo $i
}

get_api_backup_dir() {
  dir="$backup_directory""$source_namespace"/api
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_api_live_dir() {
  dir="$live_directory""$destination_namespace"/api
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_policy_backup_dir() {
  dir="$backup_directory""$source_namespace"/policy
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

get_policy_live_dir() {
  dir="$live_directory""$destination_namespace"/policy
  [ ! -d "$dir" ] && mkdir -p "$dir"
  echo "$dir"
}

scan() {
  i=0
  for name in $(kubectl get "$1" -n "$source_namespace" -o name); do
    i=$((i+1))
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
  while read -r line
  do
    if [[ $line == *"$2"* ]]; then
      k8s_object="$(echo "$line" | awk '{print $2}')"
      echo "$k8s_object"
      return
    fi
  done <<< "$(kubectl get "$1" -A -o=custom-columns='name:.metadata.name,namespace:.metadata.namespace')"
  echo "$k8s_object"
}

find_operator() {
  operator_namespace=$(find_k8s_object "deployments" "tyk-operator-controller-manager")
  if [ "$operator_namespace" == "" ] 
  then
    echo "No Operator found in the Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
  echo "Validated the existence of an Operator in the Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
}

validate_destination_context() {
  switch_kubeconfig "$destination_kubeconfig"
  find_operatorcontext
  find_operator
  switch_kubeconfig "$source_kubeconfig"
}

validate_source_context() {
  switch_kubeconfig "$source_kubeconfig"
  find_operator
}

find_operatorcontext() {
  operatorcontext_namespace=$(find_k8s_object "operatorcontext" "$operatorcontext")
  if [ "$operatorcontext_namespace" != "" ] 
  then
    echo "Validated the existence of the Operator Context $operatorcontext in the Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
    if [ "$destination_namespace" == "" ] 
    then
      destination_namespace=$operatorcontext_namespace  
    fi
  else
    echo "The Operator Context $operatorcontext wasn't found in Current Kubernetes Context $(get_kubeconfig) (deployment.apps/tyk-operator-controller-manager)"
  fi
}

shutdown_operator()
{
  echo "Shuting Down Tyk Operator for Kubernetes Context $(get_kubeconfig)"
  operator_replica_count=$(kubectl get deployments tyk-operator-controller-manager -n tyk -o jsonpath="{.spec.replicas}")
  kubectl scale deployment tyk-operator-controller-manager --replicas 0 -n "$operator_namespace" > /dev/null
  echo "Tyk Operator is Shutdown (Scaled Down)"
}

startup_operator()
{
  echo "Starting Up Tyk Operator for Kubernetes Context $(get_kubeconfig)"
  kubectl scale deployment tyk-operator-controller-manager --replicas "$operator_replica_count" -n "$operator_namespace" > /dev/null
  echo "Tyk Operator is up"
}

migrate_crd() {
  echo "Migrating CRDs from Backup"
  switch_kubeconfig "$destination_kubeconfig"
  restore_api
  restore_policy
  switch_kubeconfig "$source_kubeconfig"
}

restore() {
  files=$(ls "$1")

  for file in $files; do
    crd=$(cat "$1"/"$file")
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
  echo "$crd" | kubectl apply -f - -n "$destination_namespace" > /dev/null
}

store() {
  echo "$1" > "$2"
}

prepare() {
  crd=$1
  crd=$(echo "$crd" | yq "del(.metadata.annotations, .metadata.creationTimestamp, .metadata.finalizers, .metadata.generation, .metadata.namespace, .metadata.resourceVersion, .metadata.uid, .spec.contextRef, .status)" -)
  crd=$(echo "$crd" | yq '.spec.contextRef.name = '\""$operatorcontext"\"', .spec.contextRef.namespace = '\""$operatorcontext_namespace"\" -)
  echo "$crd"
}

prerequisites() {
  source_namespace=$1
  operatorcontext=$4

  check_kubeconfigs "$2" "$3"
  validate_source_context
  scan_namespace
  validate_destination_context

  if [[ $operator_namespace != "" && $operatorcontext_namespace != "" && $source_kubeconfig != "" && $destination_kubeconfig != "" && $is_crds_available ]]; 
  then
    is_migratable=1
  else
    is_migratable=0
  fi
}

check_kubeconfigs() {
  echo "Validating Kube Configs..."
  if [ "$(check_kubeconfig "$1")" ]; then
    source_kubeconfig=$1
    echo "Validated the Source Kube Config $1"
  else
    echo "Your Source Kube Config $1 doesn't exist"
  fi
  
  if [ "$(check_kubeconfig "$2")" ]; then
    destination_kubeconfig=$2
    echo "Validated the Destination Kube Config $2"
  else
    echo "Your Destination Kube Config $2 doesn't exist"
  fi
  
  switch_kubeconfig "$source_kubeconfig"
}

switch_kubeconfig() {
  kubectl config use-context "$1" > /dev/null
}

get_kubeconfig() {
  kubectl config current-context
}

check_kubeconfig() {
  for config in $(kubectl config get-contexts -o name); do
    # echo "The Kube Config for $config"
    if [ "$1" == "$config" ]
    then
      echo 1
      return
    fi 
  done
  echo 0
}

migrate() {

  prerequisites "$1" "$2" "$3" "$4"

  if [ "$is_migratable" ]
  then

    echo "Migration Starts"

    shutdown_operator
    backup_namespace
    migrate_crd
    startup_operator
  fi
}

migrate dev tyk tyk2 prod