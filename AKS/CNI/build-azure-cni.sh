# 
#
# Azure Documentation link
#
# https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni?tabs=configure-networking-portal
#
#
# Login and Useful commands
#
# List all Azure accounts in table format
#Login tenant and subscription validation
az account show
az account list -o table

#
# Creat an alias for kubectl
# alias k='kubectl'
alias k
#
# Used to manage multiple AKS clusters and configurations. 
#
k config get-contexts
k config use-context nnaks-basic
k config delete-context nnaks-azurecni27


#
# define the variable
#

MYACR=<your-acr-name>           # Azure Container Registry name
VNETRG=<your-vnet-rg>           # Resource group for the virtual network
VNET=<your-vnet-name>           # Existing Virtual network name
SUBNET=<your-subnet-name>       # Existing Subnet name within the virtual network
RG=<your-aks-rg>                # Resource group for the AKS cluster
AKSCLUSTER=<your-aks-cluster>   # AKS cluster name
AKSDNS=<your-aks-dns-prefix>    # DNS name prefix for the AKS cluster
LOC=<your-location>             # Location/region for the resources
PLUGIN=azure                    # Network plugin to use for the AKS cluster
IDENTITY=<your-identity-name>   # Managed identity name


# Create Resource Group
az group create --name $RG --location $LOC

#
# Create ACR in $RG
#
az acr create --resource-group $RG --name $MYACR --sku Basic


# Get the virtual network resource ID
VNET_ID=$(az network vnet show --resource-group $VNETRG --name $VNET --query id -o tsv)
echo $VNET_ID

# Get the virtual network subnet resource ID
SUBNET_ID=$(az network vnet subnet show --resource-group $VNETRG --vnet-name $VNET --name $SUBNET --query id -o tsv)
echo $SUBNET_ID

# Create IDENTITY
# This will be the identity assigned to the AKS cluster.
az identity create --name $IDENTITY --resource-group $RG
az identity list --resource-group $RG

# Save the principal ID in a variable
principal_id=$(az identity list --resource-group $RG --query '[0].principalId' -o tsv)
echo $principal_id

# Save the id of the managed identity in a variable
identity_id=$(az identity list --resource-group $RG --query "[?name=='$IDENTITY'].id" -o tsv)
echo $identity_id


#
# The command assigns the "Network Contributor" role to the specified principal within the scope of the specified Virtual Network. 
# This grants the principal permissions to manage network resources within that VNet.
az role assignment create --assignee $principal_id --scope $VNET_ID --role "Network Contributor"
az role assignment list --assignee $principal_id --scope $VNET_ID --role "Network Contributor"

# Create AKS cluster
#
# --name sets the name of the AKS cluster.
# --dns-name-prefix sets the prefix for the DNS name of the AKS cluster's API server and unique within the Azure Region

az aks create \
    --resource-group $RG \
    --name $AKSCLUSTER \
    --node-count 3 \
    --generate-ssh-keys \
    --enable-addons monitoring \
    --dns-name-prefix $AKSDNS \
    --network-plugin $PLUGIN \
    --service-cidr 10.101.0.0/16 \
    --dns-service-ip 10.101.0.10 \
    --docker-bridge-address 172.20.0.1/16 \
    --vnet-subnet-id $SUBNET_ID \
    --assign-identity $identity_id \
    --attach-acr $MYACR \
    --max-pods 30 \
    --verbose

# Get AKS cluster credentials
az aks get-credentials -g $RG -n $AKSCLUSTER
k get nodes -o wide
# cluster FQDN
kubectl config get-contexts
az aks show --resource-group $RG --name $AKSCLUSTER --query "fqdn" -o tsv

# Create namespace and deploy application
k create ns demo-ns
k apply -f deployment.yaml
k get nodes,service,pods -o wide -n demo-ns

# Apply external load balancer service
k apply -f service-external-lb.yaml
k get service -n demo-ns --watch
k get nodes,pods,service -o wide -n demo-ns

# Apply internal load balancer service
k apply -f service-internal-lb.yaml
k get service -n demo-ns --watch
k get nodes,pods,services -o wide -n demo-ns

# Verify inbound and outbound flows
k exec -it <nginx-pod-name> -n demo-ns -- curl ifconfig.me
curl <external-ip>:8080

# Describe services
k describe service nginx-service-external -n demo-ns
k describe service nginx-service-internal -n demo-ns

#
#
# Troubleshooting
az aks show --resource-group $RG --name $AKSCLUSTER --query "fqdn" -o tsv
#
# Troubleshooting:
#
k get events -n demo-ns
#
# Internal LB permissions issue
# Example error message when there is a permissions issue with the internal load balancer
# 23s         Warning   SyncLoadBalancerFailed   service/red-service-internal   Error syncing load balancer: failed to ensure load balancer: Retriable: false, RetryAfter: 0s, HTTPStatusCode: 403, RawError: Retriable: false, RetryAfter: 0s, HTTPStatusCode: 403, RawError: {"error":{"code":"AuthorizationFailed","message":"The client 'e3ba4b52-fd38-44fc-8b4b-ff3e610fdc2b' with object id 'e3ba4b52-fd38-44fc-8b4b-ff3e610fdc2b' does not have authorization to perform action 'Microsoft.Network/virtualNetworks/subnets/read' over scope '/subscriptions/3e9e488a-a196-47d3-9850-297d92cc34dc/resourceGroups/nn-rg-east/providers/Microsoft.Network/virtualNetworks/nn-hub-vnet-east/subnets/aks-kubenet-subnet' or the scope is invalid. If access was recently granted, please refresh your credentials."}}

# Show the identity of the AKS cluster
az aks show -g $RG -n $AKSCLUSTER --query identity
# {
#   "principalId": "e3ba4b52-fd38-44fc-8b4b-ff3e610fdc2b",
#   "tenantId": "72f988bf-86f1-41af-91ab-2d7cd011db47",
#   "type": "SystemAssigned",
#   "userAssignedIdentities": null
# }

# Note: It takes time for the role assignment to propagate
az role assignment list --assignee $principal_id --scope $VNET_ID --role "Network Contributor"
az role assignment create --assignee $principal_id --scope $VNET_ID --role "Network Contributor"

# Query identity again to verify
az aks show -g $RG -n $AKSCLUSTER --query identity
#
# Verifty DNS
#
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get svc -n kube-system kube-dns
kubectl describe svc -n kube-system kube-dns
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get svc -n kube-system kube-dns


# Cleanup
# Delete the resource group to clean up all resources
az group delete --name $RG