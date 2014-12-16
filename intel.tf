provider "aws" {
	access_key = "${var.aws_access_key}"
	secret_key = "${var.aws_secret_key}"
	region = "${var.aws_region}"
}

module "vpc" {
  source = "github.com/cloudfoundry-community/terraform-aws-vpc"
  network = "${var.network}"
  aws_key_name = "${var.aws_key_name}"
  aws_access_key = "${var.aws_access_key}"
  aws_secret_key = "${var.aws_secret_key}"
  aws_region = "${var.aws_region}"
  aws_key_path = "${var.aws_key_path}"
}

module "cf" {
  source = "github.com/cloudfoundry-community/terraform-aws-cf"
  network = "${var.network}"
  aws_key_name = "${var.aws_key_name}"
  aws_access_key = "${var.aws_access_key}"
  aws_secret_key = "${var.aws_secret_key}"
  aws_region = "${var.aws_region}"
  aws_key_path = "${var.aws_key_path}"
  aws_vpc_id = "${module.vpc.aws_vpc_id}"
  aws_internet_gateway_id = "${module.vpc.aws_internet_gateway_id}"
  aws_route_table_public_id = "${module.vpc.aws_route_table_public_id}"
  aws_route_table_private_id = "${module.vpc.aws_route_table_private_id}"
  aws_subnet_lb_availability_zone = "${module.vpc.aws_subnet_bastion_availability_zone}"
}

resource "aws_instance" "bastion" {
  ami = "${lookup(var.aws_ubuntu_ami, var.aws_region)}"
  instance_type = "m1.medium"
  key_name = "${var.aws_key_name}"
  associate_public_ip_address = true
  security_groups = ["${module.vpc.aws_security_group_bastion_id}"]
  subnet_id = "${module.vpc.bastion_subnet}"

  tags {
   Name = "inception server"
  }

  connection {
    user = "ubuntu"
    key_file = "${var.aws_key_path}"
  }

  provisioner "file" {
    source = "${path.module}/provision.sh"
    destination = "/home/ubuntu/provision.sh"
  }

  provisioner "remote-exec" {
    inline = [
        "chmod +x /home/ubuntu/provision.sh",
        "/home/ubuntu/provision.sh ${var.aws_access_key} ${var.aws_secret_key} ${var.aws_region} ${module.vpc.aws_vpc_id} ${module.vpc.aws_subnet_microbosh_id} ${var.network} ${module.cf.aws_eip_cf_public_ip} ${module.cf.aws_subnet_cfruntime-2a_id} ${module.cf.aws_subnet_cfruntime-2a_availability_zone} ${aws_instance.bastion.availability_zone} ${aws_instance.bastion.id} ${module.cf.aws_subnet_lb_id} ${module.cf.aws_security_group_cf_name} ${var.cf_admin_pass}",
    ]
  }

}

module "cloudera" {
  source = "github.com/teancom/terraform-aws-cloudera"
  network = "${var.network}"
  aws_centos_ami = "${lookup(var.aws_centos_ami, var.aws_region)}"
  aws_key_name = "${var.aws_key_name}"
  aws_key_path = "${var.aws_key_path}"
  aws_access_key = "${var.aws_access_key}"
  aws_secret_key = "${var.aws_secret_key}"
  aws_vpc_id = "${module.vpc.aws_vpc_id}"
  aws_route_table_private_id = "${module.vpc.aws_route_table_private_id}"
  aws_subnet_bastion = "${module.vpc.bastion_subnet}"
  hadoop_instance_count = "${var.hadoop_instance_count}" 
  hadoop_instance_type = "${var.hadoop_instance_type}" 
}
