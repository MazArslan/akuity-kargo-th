#!/bin/bash

## Log it
echo "post-start start" >> ~/.status.log

## Export Kubeconfig 
k3d kubeconfig write kargo-quickstart | tee -a ~/.status.log

## Best effort env loading
source ~/.bashrc

## Log it
echo "post-start complete" >> ~/.status.log

arch=$(uname -m); [ "$arch" = "x86_64" ] && arch=amd64
curl -L -o /tmp/kargo "https://github.com/akuity/kargo/releases/latest/download/kargo-linux-${arch}"
chmod +x /tmp/kargo
sudo mv /tmp/kargo /usr/local/bin/kargo
hash -r
