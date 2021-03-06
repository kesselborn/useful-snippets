#!/bin/bash

KINDCONFIG=kind.kubeconfig
CLUSTER_NAME=test
INGRESS_PORT_HTTP=80   # must not be used by somebody else
INGRESS_PORT_HTTPS=443 # must not be used by somebody else

: ${CLUSTER_NAME:?}

_functions() {
  grep '\(^[A-Za-z].*()[ ]*{\|^###*$\)' $0|grep -v '^__'|sed -e 's/^/	/g' -e "s/^###*/\\\n/g" -e 's/()//g'|tr -d '{#'
}


_usage() {
  cat<<EOF
Usage: $0 COMMAND

available commands:
  $(echo "$(_functions)")
EOF
}

compl() {                        # print code for bash completion; execute with eval
  echo "$0"|grep "^\." > /dev/null && local exe=$0 || local exe=$(basename $0)
  local compl_func_name=_$(echo $(basename $0)|tr ' -' '_')
  local func_names=$(_functions|grep -v "compl "|sed 's/ *#.*$//g'|cut -f1 -d" "|tr -d '\n')

  echo "execute this function with 'eval \$(${exe} compl)'" >&2
  echo "$compl_func_name() { COMPREPLY=( \$(compgen -W \"${func_names}\" -- \${COMP_WORDS[COMP_CWORD]}) ); }; complete -F ${compl_func_name} ${exe}"
}

_install_kind() {
  test -e ./kind && return
  curl -Lo ./kind https://github.com/kubernetes-sigs/kind/releases/download/v0.6.1/kind-$(uname)-amd64
  chmod +x ./kind
}

#####################
launch_kind_cluster() {          # launch kind cluster for experimentation
  set -e
  _install_kind
  KUBECONFIG=${KINDCONFIG} kubectl cluster-info &>/dev/null && return
  cat<<-EOF>kind.conf
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    apiVersion: kubeadm.k8s.io/v1beta2
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
        authorization-mode: "AlwaysAllow"
  extraPortMappings:
  - containerPort: 80
    hostPort: ${INGRESS_PORT_HTTP}
  - containerPort: 443
    hostPort: ${INGRESS_PORT_HTTPS}
	EOF

  ./kind create cluster  --name ${CLUSTER_NAME} --kubeconfig ${KINDCONFIG} --config kind.conf

  printf "waiting for node to become ready "
  (set +x
  for _ in $(seq 0 120)
  do
    sleep 1
    printf "."
    kubectl get nodes|grep " Ready " && break
  done
  )
 KUBECONFIG=${KINDCONFIG}
}


delete_kind_cluster() {          # deletes the kind cluster
  ./kind delete cluster --name ${CLUSTER_NAME} --kubeconfig ${KINDCONFIG}
}

load_image() {                   # load docker image into cluster
  local image_name=$1
  : ${image_name:?}
  (set -x; ./kind load docker-image --name ${CLUSTER_NAME} --nodes ${CLUSTER_NAME}-control-plane "${image_name}")
}

pause_kind_cluster() {           # pauses the kind cluster
  docker pause ${CLUSTER_NAME}-control-plane
}

unpause_kind_cluster() {         # pauses the kind cluster
  docker unpause ${CLUSTER_NAME}-control-plane
}

install_ingress_controller() {   # installs and sets up ingress controller
  kubectl apply --wait -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v0.44.0/deploy/static/provider/cloud/deploy.yaml
  kubectl patch deployments -n ingress-nginx ingress-nginx-controller -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"controller\",\"ports\":[{\"containerPort\":80,\"hostPort\":80},{\"containerPort\":443,\"hostPort\":443}]}],\"nodeSelector\":{\"ingress-ready\":\"true\"},\"tolerations\":[{\"key\":\"node-role.kubernetes.io/master\",\"operator\":\"Equal\",\"effect\":\"NoSchedule\"}]}}}}"
}

################

install_manifests() {            # installs all *.yaml manifests
  local manifest_files=$(ls -1 *.yaml; echo "ALL";)
  echo "${manifest_files}"|cat -n
  read -n 1 -p "which file do you want to use for signup data input (type the number)? " n
  echo

  local file=$(echo "${manifest_files}"|head -n $n|tail -n1)

  if [ "${file}" = "ALL" ]
  then
    (set -x; echo "${manifest_files}"|grep -v "^ALL$" |xargs -n 1 kubectl apply --wait -f)
  else
    (set -x; kubectl apply --wait -f "${file}")
  fi
}

setup_cluster_and_install_apps() {
  launch_kind_cluster
  install_ingress_controller     installs and sets up ingress controller
  install_manifests              installs all *.yaml manifests
}


if [ -z "$1" ] || ! echo $(_functions)|grep $1 >/dev/null
then
  _usage
  exit 1
fi

test -e ${KINDCONFIG} && export KUBECONFIG=${KINDCONFIG}

"$@"

