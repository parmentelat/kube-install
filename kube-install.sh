########## pseudo docstrings
MYDIR=$(dirname $(readlink -f $BASH_SOURCE))
cd $MYDIR

# for the mac where readlink has no -f option
[ -z "$MYDIR" ] && MYDIR=$(dirname $BASH_SOURCE)
[ -z "$_sourced_r2labutils" ] && source ${MYDIR}/r2labutils.sh

create-doc-category kube "commands to manage the kube cluster"


##################################################### imaging

## references

### fedora

# our version: f35
# https://kubernetes.io/docs/setup/production-environment/container-runtimes/#cri-o
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

# still needed afterwards is tweaking your firewall

### ubuntu - no longer supported

# our version: 21.04
# https://www.techrepublic.com/article/how-to-install-kubernetes-on-ubuntu-server-without-docker/

# * silence apt install, esp. painful about kernel upgrades, that won't reboot on their own
# (as if it could reboot...)
export DEBIAN_FRONTEND=noninteractive

# all nodes
function prepare() {
    # NOTE 1: ubuntu
    # this has not been extensively tested on ubuntu
    # in addition, on ubuntu still, it seems there is a need to do also
    # ufw disable
    # # xxx probably needs to be mode more permanent
    # NOTE 2: trying to mask services marked as swap looked promising
    # but not quite right
    touch /etc/systemd/zram-generator.conf
    swapoff -a

    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
  modprobe -a $(cat /etc/modules-load.d/k8s.conf)

  cat <<EOF > /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables = 1
EOF
    sysctl -p /etc/sysctl.d/k8s.conf
}

function update-os() {
    [ -f /etc/fedora-release ] && dnf -y update
    [ -f /etc/lsb-release ]    && apt -y update
}

function install() {
    install-k8s
    install-extras
    install-helm
}

# all nodes
function install-extras() {
    [ -f /etc/fedora-release ] && dnf -y install git openssl netcat jq buildah
    [ -f /etc/lsb-release ]    && apt -y install git openssl netcat # jq
}


# all nodes
function install-k8s() {
    [ -f /etc/fedora-release ] && fedora-install-k8s
    [ -f /etc/lsb-release ]    && ubuntu-install-k8s
    fetch-kube-images
}


function fedora-install-k8s() {
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
exclude=kubelet kubeadm kubectl
EOF

    # Set SELinux in permissive mode (effectively disabling it)
    setenforce 0
    sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

    dnf -y install kubelet kubeadm kubectl --disableexcludes=kubernetes

    systemctl enable --now kubelet

    # find proper cri-o version (closest to your installed kube's)

    # defines VERSION_ID
    source /etc/os-release

    KVERSION=$(rpm -q kubectl | sed -e s/kubectl-// | cut -d. -f1,2)
    echo found kubectl version as $KVERSION
    dnf module list cri-o
    case $VERSION_ID in
        34) CVERSION=1.21;;
        35) CVERSION=1.22;;
        *) echo WARNING: you should define CVERSION for fedora $VERSION_ID; CVERSION=$KVERSION;;
    esac
    echo using cri-o CVERSION=$CVERSION

    dnf -y --disableexcludes=kubernetes module enable cri-o:$CVERSION
    dnf -y --disableexcludes=kubernetes install cri-o

    systemctl daemon-reload
    systemctl enable --now crio
}


function ubuntu-install-k8s() {
    apt update && apt -y upgrade
    apt -y install containerd
    mkdir -p /etc/containerd/ ; containerd config default > /etc/containerd/config.toml

    apt -y install apt-transport-https
    curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
    apt update && apt -y install kubelet kubeadm kubectl
}

##################################################### in-between
# should be done in the image, but early images do not have it
# plus, this probably refreshes the latests image so it makes sense at run-time too

function fetch-kube-images() {
    kubeadm config images pull
}
doc-kube fetch-kube-images "retrieve kube core images from dockerhub or similar"


##################################################### run-time


# master only
# the *`kubeadm init ..`* command issues a *`kubeadm join`* command that must be copied/pasted ...
ADMIN_LOG=$MYDIR/kubeadm-init.log

function create-cluster() {
    cluster-init
    cluster-networking

    echo "========== to join this cluster (see $ADMIN_LOG)"
    tail -2 $ADMIN_LOG
    echo "=========="
}
doc-kube create-cluster "start a kube cluster with the current node as a master"

function cluster-init() {

    # tmp xxx reinstate when not in devel mode
    #fetch-kube-images

    swapoff -a

    # spot the config file for that host
    local localconfigin="${MYDIR}/$(hostname)-config.sh.in"
    local localconfig="${MYDIR}/$(hostname)-config.sh"

    local kubeadm_token=$(kubeadm token generate)

    if [ ! "$localconfig" ]; then
        echo "local config file $localconfigin not found - aborting"
        exit 1
    fi
    # set -a / set +a is for exporting the variables
    ( echo 'set -a';
      cat $localconfigin;
      echo "KUBEADM_TOKEN=\"$kubeadm_token\"";
      echo 'set +a') > $localconfig

    source $localconfig

    local output_dir=$(realpath -m ./_clusters/${K8S_CLUSTER_NAME})
    export LOCAL_CERTS_DIR=${output_dir}/pki
    mkdir -p ${output_dir}


    # get - and export - cert
    export CA_CERT_HASH=$( \
        openssl x509 -pubkey -in ${LOCAL_CERTS_DIR}/ca.crt \
        | openssl rsa -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -hex \
        | sed 's/^.* /sha256:/' )

    # the administration client certificate and related stuff
    $MYDIR/generate-admin-client-certs.sh

    # produced by the previous command
    set -a
    CLIENT_CERT_B64=$(base64 -w0  < $LOCAL_CERTS_DIR/kubeadmin.crt)
    CLIENT_KEY_B64=$(base64 -w0  < $LOCAL_CERTS_DIR/kubeadmin.key)
    CA_DATA_B64=$(base64 -w0  < $LOCAL_CERTS_DIR/ca.crt)
    set +a

    # install our config files
    local tmpl
    for tmpl in $MYDIR/yaml/*.yaml.in; do
        local b=$(basename $tmpl .in)
        echo "refreshing /etc/kubernetes/$b"
        envsubst < $tmpl > /etc/kubernetes/$b
    done

    # generate the version without certificatesDir
    sed '/certificatesDir:/d' \
       /etc/kubernetes/kubeadm-init-config+certsdir.yaml \
       > /etc/kubernetes/kubeadm-init-config.yaml \

    # define for future use
    local kubeadm_config1=/etc/kubernetes/kubeadm-init-config+certsdir.yaml
    local kubeadm_config2=/etc/kubernetes/kubeadm-init-config.yaml

    # generate certificates
    kubeadm init phase certs all --config $kubeadm_config1 > $ADMIN_LOG 2>&1

    # copy certificates in /etc
    rsync -a ${LOCAL_CERTS_DIR}/ /etc/kubernetes/pki/

    kubeadm init --skip-phases certs --config $kubeadm_config2 >> $ADMIN_LOG 2>&1

    [ -d ~/.kube ] || mkdir ~/.kube
    cp /etc/kubernetes/admin.conf ~/.kube/config
    chown root:root ~/.kube/config
}

function cluster-networking() {
    cluster-networking-flannel
}

# various options for the networking
# flannel -- https://gist.github.com/rkaramandi/44c7cea91501e735ea99e356e9ae7883
# calico  -- https://docs.projectcalico.org/getting-started/kubernetes/quickstart
# weave
function cluster-networking-flannel() {
    kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
}
function cluster-networking-calico() {
    kubectl create -f https://docs.projectcalico.org/manifests/tigera-operator.yaml
    # unfinished - see web page mentioned above
}
function cluster-networking-weave() {
    kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
}


# master only
function setup-kubeproxy() {
    ## the Kube API on localhost:8001 (master only)

    cat >> /etc/systemd/system/kubeproxy8001.service << EOF
[Unit]
Description=kubectl proxy 8001
After=network.target

[Service]
User=root
ExecStart=/bin/bash -c "/usr/bin/kubectl proxy --address=0.0.0.0 --port=8001"
StartLimitInterval=0
RestartSec=10
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable --now kubeproxy8001
    echo kube proxy running on port:8001
}
doc-kube setup-kubeproxy "create and start a kubeproxy service on port 8001"


# all nodes
function install-helm() {
    cd
    [ -f /etc/fedora-release ] && dnf -y install openssl
    curl -fsSL -o install-helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    bash install-helm.sh
    helm version
}


## testing with hello-kubernetes (master only)
function hello-world() {
    cd
    [ -f /etc/fedora-release ] && dnf -y install git
    git clone https://github.com/paulbouwer/hello-kubernetes.git
    cd hello-kubernetes
    cd deploy/helm

    helm install --create-namespace --namespace hello-kubernetes hello-world ./hello-kubernetes

    # get the LoadBalancer ip address.
    kubectl get svc hello-kubernetes-hello-world -n hello-kubernetes -o 'jsonpath={ .status.loadBalancer.ingress[0].ip }'
}
doc-kube hello-world "deploy the hello-world app"

###

# nodes
function join-cluster() {
    echo "join-cluster:
for now YOU NEED TO COPY-PASTE the output of
$0 show-join
on your master node"
}
doc-kube join-cluster "worker node: join the cluster - but not implemented"

# on the master, for the nodes
function show-join() {
    tail -2 $ADMIN_LOG
}
doc-kube show-join "master node: display the command for the workers to join"

function unjoin-cluster() {
    kubeadm reset
    echo "you might want to also run on your master something like
kubectl drain --ignore-daemonsets $(hostname)
kubectl delete nodes $(hostname)
"
}
doc-kube unjoin-cluster "worker node: quit the cluster"



for subcommand in "$@"; do
    case "$subcommand" in
        help|--help) help-kube; exit 1;;
        *) $subcommand
    esac
done

# - on a master, do
# [update-os] install prepare create-cluster setup-kubeproxy
# - on a worker, do
# [update-os] install prepare join-cluster
# - knowing that install is actually equivalent to
# install-k8s install-extras install-helm