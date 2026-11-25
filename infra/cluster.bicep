param location string
param clusterName string
param kubernetesVersion string
param nodeVmSize string
param networkDataplane string
param skuTier string
param supportPlan string

resource cluster 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: clusterName
  location: location
  tags: {
    SecurityControl: 'Ignore'
  }
  sku: {
    name: 'Base'
    tier: skuTier
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: '${clusterName}-${uniqueString(resourceGroup().id)}'
    kubernetesVersion: kubernetesVersion
    supportPlan: supportPlan
    enableRBAC: true
    autoUpgradeProfile: {
      upgradeChannel: 'none'
      nodeOSUpgradeChannel: 'NodeImage'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: 1
        vmSize: nodeVmSize
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        osDiskType: 'Managed'
        osDiskSizeGB: 64
        maxPods: 30
        orchestratorVersion: kubernetesVersion
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: networkDataplane == 'cilium' ? 'cilium' : 'calico'
      networkDataplane: networkDataplane
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      loadBalancerProfile: {
        managedOutboundIPs: {
          count: 1
        }
      }
    }
  }
}

output clusterName string = cluster.name
output clusterId string = cluster.id
