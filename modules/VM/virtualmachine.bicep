param subnetId string
param publicKey string
param publicIpId string
param vm_admin_name string

module jbnic '../vnet/nic.bicep' = {
  name: 'vm-wireguard-nic'
  params: {
    subnetId: subnetId
    publicIpId: publicIpId
  }
}

resource vmwireguard 'Microsoft.Compute/virtualMachines@2021-07-01' = {
  name: 'vm-wireguard'
  location: resourceGroup().location
  tags: {
    environment: 'work'
    zone: 'dmz'
    applicationRole: 'wireguard'
    wireguard_ip: '192.168.9.0/32'
  }
  properties: {
    osProfile: {
      computerName: 'vm-wireguard'
      adminUsername: vm_admin_name
      linuxConfiguration: {
        ssh: {
          publicKeys: [
            {
              path: '/home/${vm_admin_name}/.ssh/authorized_keys'
              keyData: publicKey
            }
          ]
        }
        disablePasswordAuthentication: true
      }
    }
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 32
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-focal-daily'
        sku: '20_04-daily-lts-gen2'
        version: '20.04.202109140'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: jbnic.outputs.nicId
        }
      ]
    }
  }
}
