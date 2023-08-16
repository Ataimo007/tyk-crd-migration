# Tyk CRD Migration

The Tyk CRD Migration Tool is used for automating the migration of CRDs ( APIs, Policies, etc ) across Kubernetes Clusters, eliminating human error while offering visibility and control over the migration process.

## Get Started

The Migration process is executed in three intermediated stages:

### migrate

The migrate command is used to automate the transfer of CRDs ( APIs, Policies, etc ) from the Source Kubernetes Cluster to the Destinaion Kubernetes Cluster

### cutover

The cutover is a follow up command executed after the migrate command used to limit the Source of Truth to only the Destination Cluster, invalidating that of the Source Cluster. This command also leaves your Cluster in an intermediate start, and so should be followed up with the Cleanup or Rollback Command.

### cleanup

The cleanup is a follow up command executed after the cutover command used to restore the Source Cluster to the Previous state and Clean up the migrated CRDs, Backup and Operation Files. After this command is executed, you can't rollback.

### rollback (alternative)

The rollback command is used to clean up the last migration attempt and restore your CRDs to the last known state.

## Migration Scenerios

### Kube Configs of Source and Destination on a Single Machine (Recommended)

The Process of Migration would involve running the following commands:
1. migrate
2. cutover
3. cleanup

### Kube Configs of Source and Destination on Seperate Machine (Not Yet Implemented)

This is possible by mapping out the two core aleady implemented functionalities to the CLI interface:

1. backup
2. restore

## CLI Manuel

### crd-migration

#### Description:

This Command Script is for automating the migration of CRDs across Kubernetes Clusters, eliminating human error while offering visibility and control over the migration process.

#### Usage: 

crd-migration COMMAND -flags [OPTIONs]*
  
#### Cmmands:

 Below are the available commands:

  migrate: The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  cutover: The Name of the KubeConfig for the Source Kubernetes Cluster
  cleanup: The Name of the KubeConfig for the Destination Kubernetes Cluster
  rollback: The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs
  operator-startup: The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs

### migrate

#### Description:

The migrate command is used to automate the transfer of CRDs ( APIs, Policies, etc ) from the Source Kubernetes Cluster to the Destinaion Kubernetes Cluster.

#### Usage: 

crd-migration migrate -n NAMESPACE [ -s SOURCE_KUBECONFIG ] -d DESTINATION_KUBECONFIG -o OPERATOR_CONTEXT

#### Flags:

Below are the available flags

  -n : NAMESPACE: The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  -s : SOURCE_KUBECONFIG: The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  -d : DESTINATION_KUBECONFIG: The Name of the KubeConfig for the Destination Kubernetes Cluster
  -o : OPERATOR_CONTEXT: The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs

### cutover

#### Description:

The cutover is a follow up command executed after the migrate command used to limit the Source of Truth to only the Destination Cluster, invalidating that of the Source Cluster. This command also leaves your Cluster in an intermediate start, and so should be followed up with the Cleanup or Rollback Command.

#### Usage:

crd-migration cutover -n NAMESPACE [ -s SOURCE_KUBECONFIG ]

#### Flags:

Below are the available flags

  -n : NAMESPACE: The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  -s : SOURCE_KUBECONFIG: The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context

### cleanup

#### Description:

The cleanup is a follow up command executed after the cutover command used to restore the Source Cluster to the Previous state and Clean up the migrated CRDs, Backup and Operation Files. After this command is executed, you can't rollback.

#### Usage:

crd-migration cleanup -n NAMESPACE [ -s SOURCE_KUBECONFIG ]

#### Flags:

Below are the available flags

  -n : NAMESPACE: The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  -s : SOURCE_KUBECONFIG: The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context

### rollback (Not Yet Implemented)

#### Description

The rollback command is used to clean up the last migration attempt and restore your CRDs to the last known state.

#### Usage:

crd-migration rollback -n NAMESPACE [ -s SOURCE_KUBECONFIG ]

#### Flags:

Below are the available flags

  -n : NAMESPACE: The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Migrate
  -s : SOURCE_KUBECONFIG: The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context
  -d : DESTINATION_KUBECONFIG: The Name of the KubeConfig for the Destination Kubernetes Cluster

### statup-operator (Not Yet Implemented)

#### Description:

The statup-operator command is a Utility Command used to restore your Tyk Operator to the Right State in the situation where the Migration doesn't complete successfully

#### Usage:

crd-migration statup-operator -n NAMESPACE [ -s SOURCE_KUBECONFIG ]

#### Flags:

Below are the available flags

  -s : SOURCE_KUBECONFIG: The Name of the KubeConfig for the Source Kubernetes Cluster. If not specified, defaults to the Current KubeConfig Context