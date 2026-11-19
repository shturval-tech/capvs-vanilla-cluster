{{/*
Expand the name of the chart.
*/}}
{{- define "capvs-vanilla-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart label.
*/}}
{{- define "capvs-vanilla-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "capvs-vanilla-cluster.labels" -}}
helm.sh/chart: {{ include "capvs-vanilla-cluster.chart" . }}
{{ include "capvs-vanilla-cluster.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "capvs-vanilla-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "capvs-vanilla-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
CAPI cluster name. Defaults to the Helm release name.
*/}}
{{- define "capvs-vanilla-cluster.clusterName" -}}
{{- default .Release.Name .Values.cluster.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Child resource name: <clusterName><suffix>, truncated to 63 characters.
Usage:
  include "capvs-vanilla-cluster.childName" (dict "root" . "suffix" "-control-plane")
*/}}
{{- define "capvs-vanilla-cluster.childName" -}}
{{- $suffix := .suffix | toString -}}
{{- $max := sub 63 (len $suffix) | int -}}
{{- $base := include "capvs-vanilla-cluster.clusterName" .root | trunc $max | trimSuffix "-" -}}
{{- printf "%s%s" $base $suffix -}}
{{- end }}

{{/*
Kubernetes version without the leading "v".
*/}}
{{- define "capvs-vanilla-cluster.kubernetesVersion" -}}
{{- .Values.cluster.kubernetesVersion | default .Chart.AppVersion | toString | trimPrefix "v" }}
{{- end }}

{{/*
API endpoint host: LB address, VIP or a single control-plane node IP.
*/}}
{{- define "capvs-vanilla-cluster.endpointHost" -}}
{{- required "cluster.endpoint.host is required. Set an external load-balancer address, a kube-vip VIP, or the static IP of a single control-plane node." .Values.cluster.endpoint.host }}
{{- end }}

{{/*
API endpoint port.
*/}}
{{- define "capvs-vanilla-cluster.endpointPort" -}}
{{- default 6443 .Values.cluster.endpoint.port | int }}
{{- end }}

{{/*
API endpoint in host:port form (IPv6-safe).
*/}}
{{- define "capvs-vanilla-cluster.endpoint" -}}
{{- $host := include "capvs-vanilla-cluster.endpointHost" . -}}
{{- $port := include "capvs-vanilla-cluster.endpointPort" . | int -}}
{{- if contains ":" $host -}}
{{- printf "[%s]:%d" $host $port -}}
{{- else -}}
{{- printf "%s:%d" $host $port -}}
{{- end -}}
{{- end }}

{{/*
Secret with vCenter credentials. Created by the chart or supplied by the user.
*/}}
{{- define "capvs-vanilla-cluster.credentialsSecretName" -}}
{{- if .Values.vsphere.credentials.existingSecret -}}
{{- .Values.vsphere.credentials.existingSecret -}}
{{- else -}}
{{- printf "%s-vsphere-credentials" (include "capvs-vanilla-cluster.clusterName" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Comma-separated node labels for kubelet --node-labels.
*/}}
{{- define "capvs-vanilla-cluster.nodeLabels" -}}
{{- $labels := .labels | default dict -}}
{{- $pairs := list -}}
{{- range $k, $v := $labels -}}
{{- $pairs = append $pairs (printf "%s=%s" $k (toString $v)) -}}
{{- end -}}
{{- join "," $pairs -}}
{{- end }}

{{/*
nodeRegistration block shared by initConfiguration and joinConfiguration.

Usage:
  include "capvs-vanilla-cluster.nodeRegistration" (dict "args" <map> "labels" <map> "taints" <list>)
*/}}
{{- define "capvs-vanilla-cluster.nodeRegistration" -}}
{{- $args := deepCopy (.args | default dict) -}}
{{- $labels := .labels | default dict -}}
{{- if and $labels (not (hasKey $args "node-labels")) -}}
{{- $_ := set $args "node-labels" (include "capvs-vanilla-cluster.nodeLabels" (dict "labels" $labels)) -}}
{{- end -}}
criSocket: unix:///var/run/containerd/containerd.sock
imagePullPolicy: IfNotPresent
{{- if $args }}
kubeletExtraArgs:
{{- range $k, $v := $args }}
- name: {{ $k }}
  value: {{ toString $v | quote }}
{{- end }}
{{- end }}
{{- if .taints }}
taints:
{{- toYaml .taints | nindent 2 }}
{{- end }}
{{- end }}

{{/*
kubeadm extraArgs list from a map.

Usage:
  include "capvs-vanilla-cluster.kubeadmExtraArgs" (dict "args" .Values.kubeadm.apiServer.extraArgs "root" .)
*/}}
{{- define "capvs-vanilla-cluster.kubeadmExtraArgs" -}}
{{- $root := .root -}}
{{- range $k, $v := (.args | default dict) }}
- name: {{ $k }}
  value: {{ tpl (toString $v) $root | quote }}
{{- end }}
{{- end }}

{{/*
Effective image for a control plane component.
The registry is always the global kubeadm.imageRepository; only the tag
is overridable per component. Kubeadm has no native per-component image
tag field, so the chart patches the generated static Pod manifests.

Usage:
  include "capvs-vanilla-cluster.controlPlaneImage" (dict "root" . "component" "kube-apiserver" "override" .Values.kubeadm.apiServer)
*/}}
{{- define "capvs-vanilla-cluster.controlPlaneImage" -}}
{{- $root := .root -}}
{{- $override := .override | default dict -}}
{{- $repo := $root.Values.kubeadm.imageRepository | default "registry.k8s.io" | trimSuffix "/" -}}
{{- $tag := $override.imageTag | default (printf "v%s" (include "capvs-vanilla-cluster.kubernetesVersion" $root)) -}}
{{- printf "%s/%s:%s" $repo .component $tag -}}
{{- end }}

{{/*
Strategic merge patch for one control plane static Pod.
*/}}
{{- define "capvs-vanilla-cluster.controlPlaneImagePatch" -}}
spec:
  containers:
    - name: {{ .component }}
      image: {{ include "capvs-vanilla-cluster.controlPlaneImage" (dict "root" .root "component" .component "override" .override) | quote }}
{{- end }}

{{/*
True if any per-component control plane image override is set.
*/}}
{{- define "capvs-vanilla-cluster.hasControlPlaneImagePatches" -}}
{{- $api := .Values.kubeadm.apiServer | default dict -}}
{{- $cm := .Values.kubeadm.controllerManager | default dict -}}
{{- if or $api.imageTag $cm.imageTag -}}
true
{{- end -}}
{{- end }}

{{/*
Kubeadm patch files for kube-apiserver and kube-controller-manager images.
*/}}
{{- define "capvs-vanilla-cluster.controlPlaneImagePatches" -}}
{{- $root := . -}}
{{- $api := $root.Values.kubeadm.apiServer | default dict -}}
{{- $cm := $root.Values.kubeadm.controllerManager | default dict -}}
{{- if $api.imageTag }}
- path: /etc/kubernetes/patches/kube-apiserver.yaml
  content: {{ include "capvs-vanilla-cluster.controlPlaneImagePatch" (dict "root" $root "component" "kube-apiserver" "override" $api) | b64enc | quote }}
  encoding: base64
  owner: root:root
  permissions: "0644"
{{- end }}
{{- if $cm.imageTag }}
- path: /etc/kubernetes/patches/kube-controller-manager.yaml
  content: {{ include "capvs-vanilla-cluster.controlPlaneImagePatch" (dict "root" $root "component" "kube-controller-manager" "override" $cm) | b64enc | quote }}
  encoding: base64
  owner: root:root
  permissions: "0644"
{{- end }}
{{- end }}

{{/*
VSphereMachineTemplate spec for a group.

Usage:
  include "capvs-vanilla-cluster.machineSpec" (dict "root" . "group" .Values.controlPlane "name" "control-plane")
*/}}
{{- define "capvs-vanilla-cluster.machineSpec" -}}
{{- $root := .root -}}
{{- $group := .group | default dict -}}
{{- $name := .name | default "machine" -}}
{{- $v := $root.Values.vsphere -}}
{{- $vm := merge (dict) ($group.vm | default dict) ($v.vm | default dict) -}}
{{- $network := $group.network | default $v.network -}}
{{- $devices := $network.devices | default list -}}
{{- if not $devices -}}
{{- fail (printf "network.devices is required for %s" $name) -}}
{{- end -}}
{{- range $devices -}}
{{- if not .networkName -}}
{{- fail (printf "network.devices[].networkName is required for %s" $name) -}}
{{- end -}}
{{- if .ipAddrs -}}
{{- fail (printf "network device %q for %s: ipAddrs cannot be set in VSphereMachineTemplate (CAPV v1beta2 webhook). Use addressesFromPools with an IPAM provider or a DHCP reservation." .networkName $name) -}}
{{- end -}}
{{- if and .dhcp4 .addressesFromPools -}}
{{- fail (printf "network device %q for %s: dhcp4=true cannot be combined with addressesFromPools" .networkName $name) -}}
{{- end -}}
{{- if and (not .dhcp4) (not .addressesFromPools) (not .skipIPAllocation) -}}
{{- fail (printf "network device %q for %s: dhcp4=false requires addressesFromPools or skipIPAllocation; for a single VM use a DHCP reservation instead of ipAddrs" .networkName $name) -}}
{{- end -}}
{{- end -}}

{{- $spec := dict -}}
{{- $_ := set $spec "server" (required (printf "vsphere.server is required for %s" $name) ($group.server | default $v.server)) -}}
{{- $_ := set $spec "datacenter" (required (printf "vsphere.datacenter is required for %s" $name) ($group.datacenter | default $v.datacenter)) -}}
{{- $_ := set $spec "datastore" (required (printf "vsphere.datastore is required for %s" $name) ($group.datastore | default $v.datastore)) -}}
{{- $_ := set $spec "folder" (required (printf "vsphere.folder is required for %s" $name) ($group.folder | default $v.folder)) -}}
{{- $_ := set $spec "template" (required (printf "vsphere.template is required for %s" $name) ($group.template | default $v.template)) -}}
{{- $_ := set $spec "cloneMode" ($group.cloneMode | default $v.cloneMode | default "linkedClone") -}}
{{- $_ := set $spec "powerOffMode" ($group.powerOffMode | default $v.powerOffMode | default "trySoft") -}}
{{- $_ := set $spec "os" ($group.os | default $v.os | default "Linux") -}}
{{- $_ := set $spec "numCPUs" (required (printf "vm.numCPUs is required for %s" $name) $vm.numCPUs | int) -}}
{{- $_ := set $spec "memoryMiB" (required (printf "vm.memoryMiB is required for %s" $name) $vm.memoryMiB | int) -}}
{{- $_ := set $spec "diskGiB" (required (printf "vm.diskGiB is required for %s" $name) $vm.diskGiB | int) -}}
{{- $_ := set $spec "network" (dict "devices" $devices) -}}
{{- with ($group.resourcePool | default $v.resourcePool) }}
{{- $_ := set $spec "resourcePool" . -}}
{{- end }}
{{- with ($group.storagePolicyName | default $v.storagePolicyName) }}
{{- $_ := set $spec "storagePolicyName" . -}}
{{- end }}
{{- with ($group.thumbprint | default $v.thumbprint) }}
{{- $_ := set $spec "thumbprint" . -}}
{{- end }}
{{- with ($vm.additionalDisksGiB | default list) }}
{{- $_ := set $spec "additionalDisksGiB" . -}}
{{- end }}
{{- with ($group.extraSpec | default dict) }}
{{- $spec = mergeOverwrite $spec . -}}
{{- end }}
{{- toYaml $spec -}}
{{- end }}

{{/*
preKubeadmCommands. Every node gets a stable hostname and /etc/hosts.
When kube-vip is enabled, run the prepare scripts written to
/etc/pre-kubeadm-commands (same workaround as upstream CAPV templates).

Usage:
  include "capvs-vanilla-cluster.preKubeadmCommands" (dict "kubeVip" true "extra" <list>)
*/}}
{{- define "capvs-vanilla-cluster.preKubeadmCommands" -}}
{{- $hostname := "{{ ds.meta_data.hostname }}" -}}
- hostnamectl set-hostname "{{ $hostname }}"
- echo "::1         ipv6-localhost ipv6-loopback" > /etc/hosts
- echo "127.0.0.1   localhost" >> /etc/hosts
- echo "127.0.0.1   {{ $hostname }}" >> /etc/hosts
{{- if .controlPlanePatches }}
- mkdir -p /etc/kubernetes/patches
{{- end }}
- systemctl enable --now containerd
- while ! systemctl is-active --quiet containerd; do echo "Waiting for containerd..."; sleep 2; done
{{- if .kubeVip }}
- mkdir -p /etc/pre-kubeadm-commands
- for script in $(find /etc/pre-kubeadm-commands/ -name '*.sh' -type f | sort); do echo "Running script $script"; "$script"; done
{{- end }}
{{- range (.extra | default list) }}
- {{ . | quote }}
{{- end }}
{{- end }}

{{/*
KubeadmConfigSpec.files. Includes kube-vip files (optional) and user extras.

Usage:
  include "capvs-vanilla-cluster.kubeadmFiles" (dict "root" . "kubeVip" true "extraFiles" <list>)
*/}}
{{- define "capvs-vanilla-cluster.kubeadmFiles" -}}
{{- if .controlPlane }}
{{- include "capvs-vanilla-cluster.controlPlaneImagePatches" .root }}
{{- end }}
{{- if .kubeVip }}
- path: /etc/kubernetes/manifests/kube-vip.yaml
  content: {{ tpl (.root.Files.Get "conf/kube-vip.yaml") .root | b64enc | quote }}
  encoding: base64
  owner: root:root
  permissions: "0644"
- path: /etc/kube-vip.hosts
  content: {{ "127.0.0.1 localhost kubernetes" | b64enc | quote }}
  encoding: base64
  owner: root:root
  permissions: "0644"
- path: /etc/pre-kubeadm-commands/50-kube-vip-prepare.sh
  content: {{ .root.Files.Get "conf/kube-vip-prepare.sh" | b64enc | quote }}
  encoding: base64
  owner: root:root
  permissions: "0700"
{{- end }}
{{- range (.extraFiles | default list) }}
- path: {{ required "extraFiles[].path is required" .path | quote }}
  {{- with .content }}
  content: {{ . | quote }}
  {{- end }}
  {{- with .encoding }}
  encoding: {{ . | quote }}
  {{- end }}
  {{- with .owner }}
  owner: {{ . | quote }}
  {{- end }}
  {{- with .permissions }}
  permissions: {{ . | quote }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Validation shared by all templates.
*/}}
{{- define "capvs-vanilla-cluster.validate" -}}
{{- $clusterName := include "capvs-vanilla-cluster.clusterName" . -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $clusterName) -}}
{{- fail (printf "cluster.name %q must be a DNS label (lowercase alphanumeric and '-')" $clusterName) -}}
{{- end -}}
{{- if gt (len $clusterName) 52 -}}
{{- fail (printf "cluster.name %q is too long: max 52 characters (CAPI adds -kubeconfig)" $clusterName) -}}
{{- end -}}
{{- range $groupName, $_ := .Values.workerNodes -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $groupName) -}}
{{- fail (printf "workerNodes key %q must be a DNS label (lowercase alphanumeric and '-')" $groupName) -}}
{{- end -}}
{{- if gt (len $groupName) 40 -}}
{{- fail (printf "workerNodes key %q is too long: max 40 characters" $groupName) -}}
{{- end -}}
{{- end -}}
{{- $cp := .Values.controlPlane -}}
{{- if lt (int $cp.replicas) 1 -}}
{{- fail "controlPlane.replicas must be >= 1" -}}
{{- end -}}
{{- if and .Values.vsphere.credentials.create .Values.vsphere.credentials.existingSecret -}}
{{- fail "set either vsphere.credentials.create=true or vsphere.credentials.existingSecret, not both" -}}
{{- end -}}
{{- if and (not .Values.vsphere.credentials.create) (not .Values.vsphere.credentials.existingSecret) -}}
{{- fail "vsphere.credentials.create=false requires vsphere.credentials.existingSecret" -}}
{{- end -}}
{{- if .Values.kubeVip.enabled -}}
{{- $host := include "capvs-vanilla-cluster.endpointHost" . -}}
{{- $ipv4 := "^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$" -}}
{{- if not (regexMatch $ipv4 $host) -}}
{{- fail "kubeVip.enabled requires cluster.endpoint.host to be an IPv4 VIP address (ARP mode)" -}}
{{- end -}}
{{- if ne (int (include "capvs-vanilla-cluster.endpointPort" .)) 6443 -}}
{{- fail "kubeVip.enabled requires cluster.endpoint.port to be 6443 (kube-vip does not proxy ports)" -}}
{{- end -}}
{{- end -}}
{{- if .Values.ssh.enabled -}}
{{- if not .Values.ssh.authorizedKeys -}}
{{- fail "ssh.enabled=true requires at least one ssh.authorizedKeys entry" -}}
{{- end -}}
{{- end -}}
{{- end }}
