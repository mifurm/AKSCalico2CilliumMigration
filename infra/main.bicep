targetScope = 'subscription'

param location string = 'westeurope'
param resourceGroupName string = 'rg-aks-calico-support'
param clusterName string = 'aks-calico-support'
param kubernetesVersion string = '1.35.9'
param nodeVmSize string = 'Standard_D2s_v5'
@allowed([
  'azure'
  'cilium'
])
param networkDataplane string
@allowed([
  'Free'
  'Premium'
])
param skuTier string
@allowed([
  'KubernetesOfficial'
  'AKSLongTermSupport'
])
param supportPlan string

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: {
    SecurityControl: 'Ignore'
  }
}

module cluster './cluster.bicep' = {
  name: 'aks-calico-cluster'
  scope: resourceGroup
  params: {
    location: location
    clusterName: clusterName
    kubernetesVersion: kubernetesVersion
    nodeVmSize: nodeVmSize
    networkDataplane: networkDataplane
    skuTier: skuTier
    supportPlan: supportPlan
  }
}

output resourceGroupName string = resourceGroup.name
output clusterName string = cluster.outputs.clusterName
output clusterId string = cluster.outputs.clusterId
