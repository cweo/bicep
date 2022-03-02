targetScope = 'subscription'

// Parameters
param baseName string
param local_public_ip string
param aadGroupdIds array
param pubkeydata string
param vm_admin_name string
param user_object_id string

// Resource Groups
var rgName = baseName
module rg 'modules/resource-group/rg.bicep' = {
  name: rgName
  params: {
    rgName: rgName
    location: deployment().location
  }
}

// NSGs
module nsgaks 'modules/nsg/nsgaks.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'nsgaks'
  params: {}
  dependsOn: [
    rg
  ]
}

module nsgdmz 'modules/nsg/nsgdmz.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'nsgdmz'
  params: {
    local_public_ip: local_public_ip
  }
  dependsOn: [
    rg
  ]
}

module nsginternal 'modules/nsg/nsginternal.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'nsginternal'
  params: {}
  dependsOn: [
    rg
  ]
}

// VNET
module vnetsandbox 'modules/vnet/vnet.bicep' = {
  scope: resourceGroup(rg.name)
  name: baseName
  params: {
    vnetAddressSpace: {
      addressPrefixes: [
        '10.0.235.0/24'
      ]
    }
    vnetNamePrefix: baseName
    subnets: [
      {
        properties: {
          addressPrefix: '10.0.235.0/27'
          networkSecurityGroup: {
            id: nsgdmz.outputs.nsgdmzId
          }
        }
        name: 'dmz'
      }
      {
        properties: {
          addressPrefix: '10.0.235.32/27'
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: {
            id: nsginternal.outputs.nsginternalId
          }
        }
        name: 'internal'
      }
      {
        properties: {
          addressPrefix: '10.0.235.64/27'
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: {
            id: nsgaks.outputs.nsgaksId
          }
        }
        name: 'aks'
      }
    ]
  }
  dependsOn: [
    rg
  ]
}

// Wireguard Jumphost
module publicip 'modules/vnet/publicip.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'publicip'
  params: {
    publicipName: 'vm-wireguard-pip'
    publicipproperties: {
      publicIPAllocationMethod: 'Static'
      dnsSettings: {
        domainNameLabel: baseName
      }
    }
    publicipsku: {
      name: 'Standard'
      tier: 'Regional'
    }
  }
  dependsOn: [
    rg
  ]
}

module vmwireguard 'modules/VM/virtualmachine.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'vm-wireguard-jumphost'
  params: {
    subnetId: vnetsandbox.outputs.vnetSubnets[0].id
    publicKey: pubkeydata
    publicIpId: publicip.outputs.publicipId
    vm_admin_name: vm_admin_name
  }
  dependsOn: [
    rg
  ]
}

// AKS & ACR
var acrName = '${uniqueString(rgName)}acr'
module acrDeploy 'modules/acr/acr.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'acrDeploy'
  params: {
    acrName: acrName
  }
  dependsOn: [
    rg
  ]
}

module akslaworkspace 'modules/laworkspace/la.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'akslaworkspace'
  params: {
    basename: baseName
  }
  dependsOn: [
    rg
  ]
}

module privatednsAKSZone 'modules/vnet/privatednszone.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'privatednsAKSZone'
  params: {
    privateDNSZoneName: 'privatelink.${deployment().location}.azmk8s.io'
  }
  dependsOn: [
    rg
  ]
}

module aksHubLink 'modules/vnet/privatdnslink.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'aksHubLink'
  params: {
    privateDnsZoneName: privatednsAKSZone.outputs.privateDNSZoneName
    vnetId: vnetsandbox.outputs.vnetId
  }
  dependsOn: [
    rg
  ]
}

module aksIdentity 'modules/Identity/userassigned.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'aksIdentity'
  params: {
    basename: baseName
  }
  dependsOn: [
    rg
  ]
}

resource pvtdnsAKSZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: 'privatelink.${deployment().location}.azmk8s.io'
  scope: resourceGroup(rg.name)
}

module aksCluster 'modules/aks/privateaks.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'aksCluster'
  params: {
    aadGroupdIds: aadGroupdIds
    basename: baseName
    logworkspaceid: akslaworkspace.outputs.laworkspaceId
    privateDNSZoneId: privatednsAKSZone.outputs.privateDNSZoneId
    subnetId: vnetsandbox.outputs.vnetSubnets[2].id
    identity: {
      '${aksIdentity.outputs.identityid}': {}
    }
    principalId: aksIdentity.outputs.principalId
  }
  dependsOn: [
    rg
  ]
}

// synapse
module synapsedeploy 'modules/synapse/workspace.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'synapse'
  params: {
    synapseName: '${baseName}-synapse'
    location: deployment().location
    sqlAdministratorLogin: vm_admin_name
    sqlAdministratorLoginPassword: '${toLower(replace(uniqueString(subscription().id, rg.outputs.rgId), '-', ''))}#1A!'
    blobName: '${baseName}sta'
    storageAccountType: 'Standard_LRS'
    sqlpoolName: '${baseName}sqlpool'
    bigDataPoolName: '${baseName}bdpool'
    nodeSize: 'Small'
    sparkPoolMinNodeCount: 1
    sparkPoolMaxNodeCount: 1
    defaultDataLakeStorageFilesystemName: 'datalakefs'
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    startIpaddress: local_public_ip
    endIpAddress: local_public_ip
    userObjectId: user_object_id
  }
}

param blobprivatelinkDNSZoneName string = 'privatelink.blob.core.windows.net'


module privatednsBlobWindowsCoreNet 'modules/vnet/privatednszone.bicep' = {
  scope: resourceGroup(rg.name)
  name: 'privatednsBlobWindowsCoreNet'
  params: {
    privateDNSZoneName: blobprivatelinkDNSZoneName
  }
  dependsOn: [
    rg
  ]
}


param policyName string = 'storageAccountpDNSzone'

module policyDeploy 'modules/governance/policies/storageaccountpDNSzone.bicep' = {
  name: policyName
  params: {
    policyName: policyName
  }
  dependsOn: [
    rg
  ]
}


// param customPolicyDefinitionId string = 
param deployPEStorageAccountDefinitionID string = '/providers/Microsoft.Authorization/policyDefinitions/9f766f00-8d11-464e-80e1-4091d7874074'
param subnettarget string = 'internal'


param PDNSContributorGuid string = guid('PDNSContributor')
param NetworkContributorGuidPE string = guid('NetworkContributorPE')
param NetworkContributorGuidCA string = guid('NetworkContributorCA')
param StorageAccountContributorGuid string = guid('StorageAccountContributor')



var PDNSContributor = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/b12aa53e-6015-4669-85d0-8515ebb3ae7f'
var NetworkContributor = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7'
var StorageAccountContributor = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/17d1049b-9a84-46fb-8f53-869881c3d3ab'


// Policy to enforce storage account private endpoints creation towards internal subnet
resource deployPESTAAssignment 'Microsoft.Authorization/policyAssignments@2021-06-01' = {
  name: 'deployPESTAAssignment'
  scope: subscription()
  identity: {
    type: 'SystemAssigned'
  }
  
  location: deployment().location
  properties: {
      policyDefinitionId: deployPEStorageAccountDefinitionID
      parameters: {
          privateEndpointSubnetId: {
            value: '/subscriptions/${subscription().id}/resourceGroups/${rg.name}/providers/Microsoft.Network/virtualNetworks/${vnetsandbox.outputs.vnetName}/subnets/${subnettarget}'
          }
      }
   }
  dependsOn: [
    rg
  ]
}


resource roleassignmentPE 'Microsoft.Authorization/roleAssignments@2020-08-01-preview' = {
  name: StorageAccountContributorGuid
  properties: {
    principalId: deployPESTAAssignment.identity.principalId
    roleDefinitionId: StorageAccountContributor
    principalType:'ServicePrincipal'
  }
  dependsOn: [
    rg
  ]
}

resource roleassignmentPE2 'Microsoft.Authorization/roleAssignments@2020-08-01-preview' = {
  name: NetworkContributorGuidPE
  properties: {
    principalId: deployPESTAAssignment.identity.principalId
    roleDefinitionId: NetworkContributor
    principalType:'ServicePrincipal'
  }
  dependsOn: [
    rg
  ]
}


// Policy to enforce that private endpoints connects to the correct private DNS zone
resource deployCustomAssignment 'Microsoft.Authorization/policyAssignments@2021-06-01' = {
  name: 'deployCustomAssignment'
  scope: subscription()
  identity: {
    type: 'SystemAssigned'
  }
  location: deployment().location
  properties: {
      policyDefinitionId: policyDeploy.outputs.storageAccountDNSPolicyId
      parameters: {
          privateDnsZoneId: {
            value: blobprivatelinkDNSZoneName
          }
      }
   }
  dependsOn: [
    rg
    policyDeploy
  ]
}


resource roleassignmentCA 'Microsoft.Authorization/roleAssignments@2020-08-01-preview' = {
  name: PDNSContributorGuid
  properties: {
    principalId: deployCustomAssignment.identity.principalId
    roleDefinitionId: PDNSContributor
    principalType:'ServicePrincipal'
  }
  dependsOn: [
    rg
  ]
}


resource roleassignmentCA2 'Microsoft.Authorization/roleAssignments@2020-08-01-preview' = {
  name: NetworkContributorGuidCA
  properties: {
    principalId: deployCustomAssignment.identity.principalId
    roleDefinitionId: NetworkContributor
    principalType:'ServicePrincipal'
  }
  dependsOn: [
    rg
  ]
}


