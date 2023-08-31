# Tyk CRD Migration

The Tyk CRD Migration Tooling is used for automating the migration of CRDs ( APIs, Policies, etc ) across Kubernetes Clusters, offering visibility and control over the migration process.

## Prequisites
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- [yq](https://github.com/mikefarah/yq)
- [git](https://github.com/git-guides/install-git) (For Retrieving the Migration Script)

# Migration Scenerios

Below are the steps to migrate your CRDs based on known scenerios:

## Migrating CRDS across Kubernetes Clusters with Isolated Tyk Dashboards (Recommended)

You have two Kubernetes Clusters running Tyk Setup and you want to transfer all your Custom Resource Definitions from One Cluster to another.

Initial steps:

1. Check if you have a configuration context for each of your Kubernetes Clusters

        > kubectl config get-contexts

        CURRENT   NAME   CLUSTER   AUTHINFO               NAMESPACE
                  tyk    tyk       clusterUser_tyk_tyk    
                  tyk2   tyk2      clusterUser_tyk_tyk2   

2. You can initialise a Kubeconfig for your Kubernetes Clusters, but this will vary depending on your Kubernetes Provider. For this example we are making use of Azure Kubernetes Service, but this will differ for Cloud Providers like [AWS](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html#create-kubeconfig-automatically) or local Providers like [minikube](https://minikube.sigs.k8s.io/docs/faq/#how-can-i-create-more-than-one-cluster-with-minikube).

        > az aks get-credentials --resource-group myResourceGroup --name myAKSCluster1
        > az aks get-credentials --resource-group myResourceGroup --name myAKSCluster2

Next will be to run the migration tooling. Below are the CRDs we want to migrate in a specific Namespace with it's associated Tyk Operator Context (i.e. which Tyk Dashboard the operation is executed against for a given resource):

**APIs**
    
    > kubectl get tykapis -A
    
    NAMESPACE   NAME            DOMAIN   LISTENPATH   PROXY.TARGETURL                              ENABLED   STATUS
    dev         httpbin-jwt              /jwt         http://httpbin.upstreams.svc.cluster.local   true      Successful
    dev         httpbin-token            /token       http://httpbin.upstreams.svc.cluster.local   true      Successful

**Polices**
    
    > kubectl get tykpolicies --all-namespaces

    NAMESPACE   NAME          AGE
    dev         jwt-policy    4m5s
    dev         protect-api   3m59s

**Operator Context**
    
    > kubectl get operatorcontext --all-namespaces

    NAMESPACE   NAME   AGE
    dev         dev    28d

Below is the new operator context we will be associating the migrated CRDs with:

    > kubectl config use-context tyk2
    
    Switched to context "tyk2".

    > kubectl get operatorcontext --all-namespaces

    NAMESPACE   NAME   AGE
    tyk         prod   15d

Pull the Migration Tooling Script into your local machine

    > git clone https://github.com/Ataimo007/tyk-crd-migration.git
    > cd tyk-crd-migration

Run the Migration Task. Note that the Migration is done on a specific Namespace, and you will need to specify the Kubenetes Contexts (Source and Destination) and the Operator Context (Source and Destination)

    > ./crd-migration.sh migrate -n dev -k tyk tyk2 -o dev prod
    ..............
    ..............

    Migration Report:
    API Statistics: 2 Found, 2 Backed Up, 2 Migrated
    Policy Statistics: 2 Found, 2 Backed Up, 2 Migrated
    Backed Up CRDs Directory: /Users/ataimoedem/documents/work/code/crd-migration/backup/dev/
    Live CRDs Directory: /Users/ataimoedem/documents/work/code/crd-migration/live/dev/
    Migration Complete

**Note:** You can optionally specify the Operator Context Namespace if it's not Unique within the Cluster and you don't want the script to auto look it up for you.

    > ./crd-migration.sh migrate -n dev -k tyk tyk2 -o dev/dev tyk/prod

Check and Validate the existence of the migrated CRDs in the new Cluster

    > kubectl config use-context tyk2
    Switched to context "tyk2".

    > kubectl get tykapis --all-namespaces
    NAMESPACE   NAME            DOMAIN   LISTENPATH   PROXY.TARGETURL                                 ENABLED   STATUS
    dev         httpbin-jwt              /jwt         http://httpbin.upstreams.svc.cluster.local      true      Successful
    dev         httpbin-token            /token       http://httpbin.upstreams.svc.cluster.local      true      Successful

    > kubectl get tykpolicies --all-namespaces
    NAMESPACE   NAME          AGE
    dev         jwt-policy    5m5s
    dev         protect-api   5m3s

Migration Complete!

## Cleanup

You can Clean up the CRDs in the New Cluster if you want to Test the Migration again, or in the Old Cluster if you are done validating the new CRDs and you are satisfy with the Migration.

Clean Up Old Cluster

    > ./crd-migration.sh cleanup -n dev -k tyk -o dev -b

    Clean Up Report:
    API Statistics: 2 Found, 2 Cleaned Up
    Policy Statistics: 2 Found, 2 Cleaned Up
    Clean Up Complete

**Note:** You can optionally specify the Operator Context Namespace if it's not Unique within the Cluster and you don't want they script to auto look it up for you.

    > ./crd-migration.sh cleanup -n dev -k tyk -o dev/dev -b

Clean Up New Cluster

    > ./crd-migration.sh cleanup -n dev -k tyk2 -o prod -b

    Clean Up Report:
    API Statistics: 2 Found, 2 Cleaned Up
    Policy Statistics: 2 Found, 2 Cleaned Up
    Clean Up Complete


# Roadmap

## *Migrating CRDS across Kubernetes Clusters with a Shared Tyk Dashboard (In Progress)*

This is for situations whereby both Kubernetes Clusters share the same Tyk Dashboard. The Option is available but hasn't been Mapped to the CLI Interface.

## *Migrating CRDS across Kubernetes Clusters manually (In Progress)*

This is for situations whereby the Kubeconfig of both Kubernetes Clusters initialized on the same Host Machine that will execute the Migration Tooling Script. This Option is available but hasn't been Mapped to the CLI Interface.



# CLI Reference

## crd-migration

### Description:

This Command Script is for automating the migration of CRDs across Kubernetes Clusters, eliminating human error while offering visibility and control over the migration process.

### Usage: 

    crd-migration COMMAND -flags [OPTIONs]*
  
### Cmmands:

 Below are the available commands:

  **migrate:** The Namespace in the Source KubeConfig that Contains the CRDs you want to Migrate
  
  **cleanup:** The Name of the KubeConfig for the Destination Kubernetes Cluster
  
  *cutover (Shared Dashboard) - In Progress:* The Name of the KubeConfig for the Source Kubernetes Cluster
  
  *rollback (Shared Dashboard) - Not Implemented:* The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs
  
  *operator-startup(Shared Dashboard) - Not Implemented Yet:* The Name of the Operator Context in the Destination Kubernetes Cluster for deploying the CRDs

## migrate

### Description:

The migrate command is used to automate the transfer of CRDs ( APIs, Policies, etc ) from the Source Kubernetes Cluster to the Destinaion Kubernetes Cluster.

### Usage: 

    crd-migration migrate -n NAMESPACE [ -k SOURCE_KUBECONFIG DESTINATION_KUBECONFIG ] [ -o \<NAMESPACE\>/SOURCE_OPERATOR_CONTEXT \<NAMESPACE\>/DESTINATION_OPERATOR_CONTEXT ]

### Flags:

Below are the available flags

  **-n : NAMESPACE:** The Namespace in the Source Kubernetes Cluster that Contains the CRDs you want to Migrate
  
  **-k : KUBECONFIGs:** The Names of the KubeConfig Context for the Source and Destination Kubernetes Cluster, delimited by space. For example -k source-context destination-context. You can use - to specify the current KubeConfig Context.
  
  **-o : OPERATOR_CONTEXTs:** The Names and Namespaces of the Tyk Operator Context for the Source and Destination Kubernetes Cluster of the CRDs, delimited by space. For example -o namespace/source-operator-context1 namespace/destination-operator-context2 or -o source-operator-context1 destination-operator-context2 if you want the script to auto lookup the operator namespace. You can use - as the source operator Context if you don't want it to be taken into account.

### Examples:

    ./crd-migration.sh migrate -n dev -k tyk tyk2 -o dev prod
    ./crd-migration.sh migrate -n dev -k tyk tyk2 -o dev/dev tyk/prod

## cleanup

### Description:

The cleanup command is used to delete CRDs from a namespace. This command can be executed after a successful Migration of your CRDs and if you no longer need the previous CRDs again.

### Usage:

    crd-migration cleanup -n NAMESPACE [ -k SOURCE_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_KUBECONFIG ] [ -b ]

### Flags:

Below are the available flags

  **-n : NAMESPACE:** The Namespace in the Kubernetes Cluster that Contains the CRDs you want to Clean Up
  
  **-k : KUBECONFIG:** The Name of the KubeConfig Context for the Kubernetes Cluster to Clean Up. For example -k context. The Current KubeConfig Context will be consider if not specified

  **-o : OPERATOR_CONTEXT:** The Name of the Tyk Operator Context that should be consider while Cleaning Up. For example -o operator-context. If not specified, all Tyk's CRDs will be considered for cleanup

  **-b : BACKUP:** Flag used to only Clean Up CRDs that are Backed Up. The defualt directory is considered if no Directory is specified.

### Examples:

    ./crd-migration.sh cleanup -n dev -k tyk2 -o prod -b
    ./crd-migration.sh cleanup -n dev -k tyk -o dev/dev -b

## *cutover (Shared Dashboard) - In Progress*

### Description:

The cutover is a follow up command executed after the migrate command used to limit the Source of Truth to only the Destination Cluster, invalidating that of the Source Cluster. This command also leaves your Cluster in an intermediate start, and so should be followed up with the Cleanup or Rollback Command.

### Usage:

    crd-migration cutover -n NAMESPACE [ -k SOURCE_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_KUBECONFIG ] [ -b ]

### Flags:

Below are the available flags

  **-n : NAMESPACE:** The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Cut Over
  
  **-k : KUBECONFIG:** The Name of the KubeConfig Context for the Kubernetes Cluster to Clean Up. For example -k context. The Current KubeConfig Context will be consider if not specified

  **-o : OPERATOR_CONTEXT:** The Name of the Tyk Operator Context that should be consider while Cutting Over. For example -o operator-context. If not specified, all Tyk's CRDs will be considered for cutover.

  **-b : BACKUP:** Flag used to only Cut Over CRDs that are Backed Up. The defualt directory is considered if no Directory is specified.

## *rollback (Shared Dashboard) - Not Implemented Yet*

### Description

The rollback command is used to clean up the last migration attempt and restore your CRDs to the last known state.

### Usage:

    crd-migration rollback -n NAMESPACE [ -k SOURCE_KUBECONFIG DESTINATION_KUBECONFIG ] [ -o <NAMESPACE>/SOURCE_KUBECONFIG ] [ -b ]

### Flags:

Below are the available flags

  **-n : NAMESPACE:** The Namespace in the Sourc KubeConfig that Contains the CRDs you want to Roll Back

  **-k : KUBECONFIGs:** The Names of the KubeConfig Context for the Source and Destination Kubernetes Cluster, delimited by space. For example -k source-context destination-context. You can use - to specify the current KubeConfig Context.

  **-o : OPERATOR_CONTEXT:** The Name of the Tyk Operator Context that should be consider while Rolling Back. For example -o operator-context. If not specified, all Tyk's CRDs will be considered for cleanup.

  **-b : BACKUP:** Flag used to only Roll Back CRDs that are Backed Up. The defualt directory is considered if no Directory is specified.

## *statup-operator (Shared Dashboard) - Not Implemented Yet*

### Description:

The statup-operator command is a Utility Command used to restore your Tyk Operator to the Right State in the situation where the Migration doesn't complete successfully

### Usage:

    crd-migration statup-operator [ -k SOURCE_KUBECONFIG ]

### Flags:

Below are the available flags

  **-k : KUBECONFIG:** The Name of the KubeConfig Context for the Kubernetes Cluster to Clean Up. For example -k context. The Current KubeConfig Context will be consider if not specified
