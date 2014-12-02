#!/bin/bash

# Variables passed in from terraform, see aws-vpc.tf, the "remote-exec" provisioner
AWS_KEY_ID=${1}
AWS_ACCESS_KEY=${2}
REGION=${3}
VPC=${4}
BOSH_SUBNET=${5}
IPMASK=${6}
CF_IP=${7}
CF_SUBNET=${8}
CF_SUBNET_AZ=${9}
BASTION_AZ=${10}
BASTION_ID=${11}
LB_SUBNET=${12}
CF_SG=${13}

# Prepare the jumpbox to be able to install ruby and git-based bosh and cf repos
cd $HOME
sudo apt-get update
sudo apt-get install -y git vim-nox build-essential libxml2-dev libxslt-dev libmysqlclient-dev libpq-dev libsqlite3-dev git unzip
gpg --keyserver hkp://keys.gnupg.net --recv-keys D39DC0E3
curl -sSL https://get.rvm.io | bash -s stable

# Generate the key that will be used to ssh between the inception server and the
# microbosh machine
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

# spiff is used by bosh-workspace to generate templated config files
pushd /tmp
wget https://github.com/cloudfoundry-incubator/spiff/releases/download/v1.0.3/spiff_linux_amd64.zip
unzip spiff_linux_amd64.zip
sudo mv spiff /usr/local/bin/.
popd

# Set our default ruby to 2.1.3
source /home/ubuntu/.rvm/scripts/rvm
rvm install ruby-2.1.3
rvm alias create default ruby-2.1.3

# We will not be installing documentation for all of the gems we use, which cuts
# down on both time and disk space used
cat <<EOF > ~/.gemrc
gem: --no-document
EOF

# We use fog below, and bosh-bootstrap uses it as well
cat <<EOF > ~/.fog
:default:
    :aws_access_key_id: $AWS_KEY_ID
    :aws_secret_access_key: $AWS_ACCESS_KEY
    :region: $REGION
EOF

gem install fog

cat <<EOF > /tmp/attach_volume.rb
require 'fog'

connection = Fog::Compute.new(:provider => 'AWS')
vol = connection.create_volume("$BASTION_AZ", 40)
sleep 10 #FIXME, probably with a loop that checks output or something
connection.attach_volume("$BASTION_ID", vol.data[:body]["volumeId"], "xvdc")
EOF

ruby /tmp/attach_volume.rb

# We sleep here to allow Amazon enough time to finish attaching the volume to
# the instance
sleep 10
sudo /sbin/mkfs.ext4 /dev/xvdc
sudo /sbin/e2label /dev/xvdc workspace
echo 'LABEL=workspace /home/ubuntu/workspace ext4 defaults,discard 0 0' | sudo tee -a /etc/fstab
mkdir -p /home/ubuntu/workspace
sudo mount -a
sudo chown -R ubuntu:ubuntu /home/ubuntu/workspace

# As long as we have a large volume to work with, we'll move /tmp over there
# You can always use a bigger /tmp
sudo rsync -avq /tmp/ /home/ubuntu/workspace/tmp/
sudo rm -fR /tmp
sudo ln -s /home/ubuntu/workspace/tmp /tmp

# bosh-bootstrap handles provisioning the microbosh machine and installing bosh
# on it. This is very nice of bosh-bootstrap. Everyone make sure to thank bosh-bootstrap
mkdir -p {bin,workspace/deployments,workspace/tools,workspace/deployments/bosh-bootstrap}
pushd workspace/deployments
pushd bosh-bootstrap
bundle install
gem install bosh-bootstrap bosh_cli -f
cat <<EOF > settings.yml
---
bosh:
  name: ${VPC}-keypair
provider:
  name: aws
  credentials:
    provider: AWS
    aws_access_key_id: ${AWS_KEY_ID}
    aws_secret_access_key: ${AWS_ACCESS_KEY}
  region: ${REGION}
address:
  vpc_id: ${VPC}
  subnet_id: ${BOSH_SUBNET}
  ip: ${IPMASK}.2.4
EOF

bosh-bootstrap deploy

# We've hardcoded the IP of the microbosh machine, because convenience
bosh -n target https://${IPMASK}.2.4:25555
bosh login admin admin
popd

# bosh-workspace uses bundler to install all of their gems
gem install bundler

# There is a specific branch of cf-boshworkspace that we use for terraform. This
# may change in the future if we come up with a better way to handle maintaining
# configs in a git repo
git clone -b cf-terraform http://github.com/cloudfoundry-community/cf-boshworkspace
pushd cf-boshworkspace
bundle install --path vendor/bundle
mkdir -p ssh

# Pull out the UUID of the director - bosh_cli needs it in the deployment to
# know it's hitting the right microbosh instance
DIRECTOR_UUID=$(bundle exec bosh status | grep UUID | awk '{print $2}')

# This is some hackwork to get the configs right. Could be changed in the future
/bin/sed -i "s/REGION/${CF_SUBNET_AZ}/g" deployments/cf-aws-vpc.yml
/bin/sed -i "s/CF_ELASTIC_IP/${CF_IP}/g" deployments/cf-aws-vpc.yml
/bin/sed -i "s/SUBNET_ID/${CF_SUBNET}/g" deployments/cf-aws-vpc.yml
/bin/sed -i "s/DIRECTOR_UUID/${DIRECTOR_UUID}/g" deployments/cf-aws-vpc.yml

/bin/sed -i "s/IPMASK/${IPMASK}/g" templates/cf-aws-networking.yml
/bin/sed -i "s/CF_SG/${CF_SG}/g" templates/cf-aws-networking.yml
/bin/sed -i "s/IPMASK/${IPMASK}/g" templates/cf-use-haproxy.yml
/bin/sed -i "s/LB_SUBNET/${LB_SUBNET}/g" templates/cf-use-haproxy.yml

# Upload the bosh release, set the deployment, and execute
bundle exec bosh upload release https://community-shared-boshreleases.s3.amazonaws.com/boshrelease-cf-189.tgz
bundle exec bosh deployment cf-aws-vpc
bundle exec bosh prepare deployment
bundle exec bosh -n deploy
# Speaking of hack-work, bosh deploy often fails the first time, due to packet bats
# We run it twice (it's idempotent) so that you don't have to
bundle exec bosh -n deploy
