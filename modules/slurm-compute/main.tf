resource "oci_core_instance" "ClusterCompute" {
  count               = "${length(var.InstanceADIndex)}"
  availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.InstanceADIndex[count.index] - 1], "name")}"
  compartment_id      = "${var.compartment_ocid}"
  display_name        = "${var.ClusterNameTag}compute${format("%03d", count.index+1)}"
  shape               = "${var.ComputeShapes[count.index]}"

  create_vnic_details {
    subnet_id        = "${oci_core_subnet.ClusterSubnet.*.id[index(var.ADS, var.InstanceADIndex[count.index])]}"
    display_name     = "primaryvnic"
    assign_public_ip = true
    hostname_label   = "${var.ClusterNameTag}compute${format("%03d", count.index+1)}"
  }

  source_details {
    source_type = "image"
    source_id   = "${lookup(var.ComputeImageOCID[var.ComputeShapes[count.index]], var.region)}"

    # Apply this to set the size of the boot volume that's created for this instance.
    # Otherwise, the default boot volume size of the image is used.
    # This should only be specified when source_type is set to "image".
    #boot_volume_size_in_gbs = "60"
  }

  metadata {
    ssh_authorized_keys = "${var.ssh_public_key}${data.tls_public_key.oci_public_key.public_key_openssh}"
    user_data           = "${base64encode(file(var.BootStrapFile))}"
  }

  timeouts {
    create = "60m"
  }

  freeform_tags = {
    "cluster"  = "${var.ClusterNameTag}"
    "nodetype" = "compute"
  }
}

resource "oci_core_instance" "ClusterManagement" {
  availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.ManagementAD - 1], "name")}"
  compartment_id      = "${var.compartment_ocid}"
  display_name        = "mgmt"
  shape               = "${var.ManagementShape}"

  create_vnic_details {
    # ManagementAD
    #subnet_id        = "${oci_core_subnet.ClusterSubnet.id}"
    subnet_id = "${oci_core_subnet.ClusterSubnet.*.id[index(var.ADS, var.ManagementAD)]}"

    display_name     = "primaryvnic"
    assign_public_ip = true
    hostname_label   = "mgmt"
  }

  source_details {
    source_type = "image"
    source_id   = "${var.ManagementImageOCID[var.region]}"
  }

  metadata {
    ssh_authorized_keys = "${var.ssh_public_key}${data.tls_public_key.oci_public_key.public_key_openssh}"
    user_data           = "${base64encode(file(var.BootStrapFile))}"
  }

  timeouts {
    create = "60m"
  }

  freeform_tags = {
    "cluster"  = "${var.ClusterNameTag}"
    "nodetype" = "mgmt"
  }
}

resource "null_resource" "copy_in_setup_data_mgmt" {
  depends_on = ["oci_core_instance.ClusterManagement"]

  triggers {
     cluster_instance = "${oci_core_instance.ClusterManagement.id}"
  }

  provisioner "file" {
    destination = "/home/opc/config"
    content = <<EOF
[DEFAULT]
user=${var.user_ocid}
fingerprint=${var.fingerprint}
key_file=/home/slurm/.oci/oci_api_key.pem
tenancy=${var.tenancy_ocid}
region=${var.region}
EOF

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterManagement.*.public_ip}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }

  provisioner "file" {
    destination = "/home/opc/oci_api_key.pem"
    source = "${var.private_key_path}"

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterManagement.*.public_ip}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }

  provisioner "file" {
    destination = "/home/opc/nodes.yaml"
    content = <<EOF
---
names: ["${join("\", \"", oci_core_instance.ClusterCompute.*.display_name)}"]
shapes: ["${join("\", \"", var.ComputeShapes)}"]
EOF

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterManagement.*.public_ip}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }

  provisioner "file" {
    destination = "/home/opc/shapes.yaml"
    source = "files/shapes.yaml"

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterManagement.*.public_ip}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }


  provisioner "file" {
    destination = "/home/opc/getfsipaddr"
    source = "files/getfsipaddr"

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterManagement.*.public_ip}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }

  provisioner "file" {
    destination = "/home/opc/installmpi"
    source = "files/installmpi"

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterManagement.*.public_ip}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }


  provisioner "file" {
    destination = "/home/opc/hosts"
    content = <<EOF
[management]
${oci_core_instance.ClusterManagement.display_name}
[compute]
${join("\n", oci_core_instance.ClusterCompute.*.display_name)}
EOF

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterManagement.*.public_ip}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }

  provisioner "remote-exec" {
    inline = [
      "touch sshd_config",
      "sudo cat /etc/ssh/sshd_config >> sshd_config",
      "sudo echo -e \"\n\" >> sshd_config",
      "sudo echo \"ClientAliveInterval=300\" >> sshd_config",
      "sudo echo \"ClientAliveCountMax=10\" >> sshd_config",
      "sudo mv -f /etc/ssh/sshd_config /etc/ssh/sshd_config.bak",
      "sudo cp sshd_config /etc/ssh/sshd_config",
      "sudo service sshd restart",
      "touch users.yml",
      "sudo echo \"---\" >> users.yml",
      "sudo echo \"users:\" >> users.yml",
      "sudo echo \"  - name: usernamehere\" >> users.yml",
      "sudo echo \"    key: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDgnEaelQQ4B1Kyr5wDEwAnD0hcwoj6lPRq9rWb4Dd+YpOsMahlctVV+0lKnSaarW+o1lYYqmnBXs3KR0X04IxGZ2qtjHc7FtJ70uMCT1w9zBiA/SIagRbATv0FpkHNQEIZSjtB1404eL7eavI8b/eNzxZ4n6Rr9BSg/y9GxHG0U6OHz4SmD8Rbfx3IKIEgE6+aksBPzCHE5rj95FB1hMKTmAEH2+i76Nn3REzK8T456bZc87rfN5IwKRUhaOtQbahV6QW9OBt71ZARxdTESLz0xeGaneCRhkoe/0y+GjcbQ0eGxclR0BHRgt4nsocGjbGgx5LEiRoWpiu+0pL7wSb1 opc@haojueterraform2\" >> users.yml",
      "sudo chmod 777 getfsipaddr",
      "./getfsipaddr",
#      "tar xzvf slurm-ansible-playbook.tar.gz",
#      "sed -i 's/slurm_cluster_name: cluster/slurm_cluster_name: ${var.ClusterNameTag}/g' /home/opc/slurm-ansible-playbook/group_vars/all.yml",
#      "echo \"ReturnToService=2\" >> /home/opc/slurm-ansible-playbook/roles/slurm/templates/slurm_shared.conf.j2", 
      "sudo yum install -y ansible git",
#      "nohup sudo python -u /usr/bin/ansible-pull --url=https://github.com/ACRC/slurm-ansible-playbook.git --checkout=master --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid}\" site.yml  &>> ansible-pull.log &",
      "nohup python -u /usr/bin/ansible-pull --url=https://github.com/haojue/slurm_ansible_github.git --checkout=master --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid} slurm_cluster_name=${var.ClusterNameTag}\" site.yml -vvv  &>> ansible-pull.log &",
      "sleep 16",
#      "sudo su",
#      "ls -l /root/.ansible/pull/mgmt*/ > afiles",
      "sed -i 's/slurm_cluster_name: cluster/slurm_cluster_name: ${var.ClusterNameTag}/g' /home/opc/.ansible/pull/mgmt*/group_vars/all.yml",
      "cat /home/opc/.ansible/pull/mgmt*/roles/slurm/templates/slurm_shared.conf.j2 > afiles",
      "echo \"ReturnToService=2\" >> /home/opc/.ansible/pull/mgmt*/roles/slurm/templates/slurm_shared.conf.j2", 
#      "exit",
      "echo \"${var.ssh_private_key}\" >> id_rsa_oci5",
      "chmod 600 id_rsa_oci5",
#      "nohup sudo ansible-playbook --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid}\"  --private-key id_rsa_oci5 -u \"opc\" --ssh-common-args \"-o StrictHostKeyChecking=no\" -T 8000 slurm-ansible-playbook/site.yml  >>ansible-pull.log &",
      "sleep 80",
#      "nohup sudo ansible-playbook --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid}\"  --private-key id_rsa_oci5 -u \"opc\" --ssh-common-args \"-o StrictHostKeyChecking=no\" -T 8000 slurm-ansible-playbook/slurm.yml >>ansible-pull.log &",
      "sleep 360",
#      "nohup sudo ansible-playbook --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid}\"  --private-key id_rsa_oci5 -u \"opc\" --ssh-common-args \"-o StrictHostKeyChecking=no\" -T 8000 slurm-ansible-playbook/finalise.yml  >>ansible-pull.log &",
      "sudo yes \"y\" | ssh-keygen -N \"\" -f ~/.ssh/id_rsa",
      "sleep 40",
      "sudo cp /home/opc/.ssh/id_rsa.pub /mnt/shared/", 
      "sudo cat /mnt/shared/id_rsa.pub  >> /home/opc/.ssh/authorized_keys",
      "sudo echo \"ReturnToService=2\" >> /mnt/shared/config",
      "sudo chmod 777 installmpi",
      "./installmpi",
      "sleep 10"
    ]

    connection {
        timeout = "15m"
        host = "${oci_core_instance.ClusterManagement.*.public_ip}"
        user = "opc"
        private_key = "${file(var.private_key_path)}"
        agent = false
    }
  }
}

resource "null_resource" "copy_in_setup_data_compute" {
  count = "${length(var.InstanceADIndex)}"
  depends_on = ["oci_core_instance.ClusterCompute"]

  triggers {
     cluster_instance = "${oci_core_instance.ClusterCompute.*.id[count.index]}"
  }

  provisioner "file" {
    destination = "/home/opc/hosts"
    content = <<EOF
[management]
${oci_core_instance.ClusterManagement.display_name}
[compute]
${join("\n", oci_core_instance.ClusterCompute.*.display_name)}
EOF

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterCompute.*.public_ip[count.index]}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }

  provisioner "file" {
    destination = "/home/opc/scpipaddr"
    source = "files/scpipaddr"

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterCompute.*.public_ip[count.index]}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }

  provisioner "file" {
    destination = "/home/opc/installmpi"
    source = "files/installmpi"

    connection {
      timeout = "15m"
      host = "${oci_core_instance.ClusterCompute.*.public_ip[count.index]}"
      user = "opc"
      private_key = "${file(var.private_key_path)}"
      agent = false
    }
  }

  provisioner "remote-exec" {
    inline = [
      "touch sshd_config",
      "sudo cat /etc/ssh/sshd_config >> sshd_config",
      "sudo echo -e \"\n\" >> sshd_config",
      "sudo echo \"ClientAliveInterval=300\" >> sshd_config",
      "sudo echo \"ClientAliveCountMax=10\" >> sshd_config",
      "sudo mv -f /etc/ssh/sshd_config /etc/ssh/sshd_config.bak",
      "sudo cp sshd_config /etc/ssh/sshd_config",
      "sudo service sshd restart",
      "touch hosts2",
      "sudo cat /etc/hosts >> hosts2",
      "sudo echo -e \"\n\" >> hosts2", 
      "chmod 777 scpipaddr",
      "sudo yum install expect -y",
      "echo \"${var.ssh_private_key}\" >> id_rsa_oci5",
      "chmod 600 id_rsa_oci5",
#      "tar xzvf slurm-ansible-playbook.tar.gz", 
#      "echo \"ReturnToService=2\" >> /home/opc/slurm-ansible-playbook/roles/slurm/templates/slurm_shared.conf.j2", 
      "sudo yum install -y ansible git",
#      "nohup sudo python -u /usr/bin/ansible-pull --url=https://github.com/ACRC/slurm-ansible-playbook.git --checkout=master --inventory=/home/opc/hosts site.yml &>> ansible-pull.log &",
      "nohup python -u /usr/bin/ansible-pull --url=https://github.com/haojue/slurm_ansible_github.git --checkout=master --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid} slurm_cluster_name=${var.ClusterNameTag}\" site.yml -vvv  &>> ansible-pull.log &",
      "sleep 16",
#      "sudo su", 
#      "ls -l /root/.ansible/pull/${var.ClusterNameTag}*/ > afiles",
##      "sudo echo \"ReturnToService=2\" >> /home/opc/.ansible/pull/${var.ClusterNameTag}*/roles/slurm*/templates/slurm_shared.conf.j2", 
#      "exit",
#      "nohup sudo ansible-playbook --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid}\"  --private-key id_rsa_oci5 -u \"opc\" --ssh-common-args \"-o StrictHostKeyChecking=no\" -T 8000 slurm-ansible-playbook/site.yml  >>ansible-pull.log &",
      "sleep 80",
#      "nohup sudo ansible-playbook --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid}\"  --private-key id_rsa_oci5 -u \"opc\" --ssh-common-args \"-o StrictHostKeyChecking=no\" -T 8000 slurm-ansible-playbook/slurm.yml >>ansible-pull.log &",
      "sleep 360",
#      "nohup sudo ansible-playbook --inventory=/home/opc/hosts --extra-vars=\"compartment_ocid=${var.compartment_ocid}\"  --private-key id_rsa_oci5 -u \"opc\" --ssh-common-args \"-o StrictHostKeyChecking=no\" -T 8000 slurm-ansible-playbook/finalise.yml  >>ansible-pull.log &",
      "sleep 5",
      "cd /home/opc",
      "./scpipaddr ${oci_core_instance.ClusterManagement.*.public_ip[0]}",
      "sudo cat ipaddr2  >> hosts2", 
      "sudo echo -e \"\n\" >> hosts2", 
      "sudo mv -f /etc/hosts /etc/hosts.bak",
      "sudo cp hosts2 /etc/hosts", 
      "sleep 475",
      "sudo chmod 777 installmpi",
      "./installmpi",
      "sudo cat /mnt/shared/id_rsa.pub  >> /home/opc/.ssh/authorized_keys",
      "sleep 10"
    ]

    connection {
        timeout = "15m"
        host = "${oci_core_instance.ClusterCompute.*.public_ip[count.index]}"
        user = "opc"
        private_key = "${file(var.private_key_path)}"
        agent = false
    }
  }
}
