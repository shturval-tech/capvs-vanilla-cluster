{{/*
Expand the name of the chart.
*/}}
{{- define "capv-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart label.
*/}}
{{- define "capv-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "capv-cluster.labels" -}}
helm.sh/chart: {{ include "capv-cluster.chart" . }}
{{ include "capv-cluster.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "capv-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "capv-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
CAPI cluster name. Defaults to the Helm release name.
*/}}
{{- define "capv-cluster.clusterName" -}}
{{- default .Release.Name .Values.cluster.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Child resource name: <clusterName><suffix>, truncated to 63 characters.
Usage:
  include "capv-cluster.childName" (dict "root" . "suffix" "-control-plane")
*/}}
{{- define "capv-cluster.childName" -}}
{{- $suffix := .suffix | toString -}}
{{- $max := sub 63 (len $suffix) | int -}}
{{- $base := include "capv-cluster.clusterName" .root | trunc $max | trimSuffix "-" -}}
{{- printf "%s%s" $base $suffix -}}
{{- end }}

{{/*
Kubernetes version without the leading "v".
*/}}
{{- define "capv-cluster.kubernetesVersion" -}}
{{- .Values.cluster.kubernetesVersion | default .Chart.AppVersion | toString | trimPrefix "v" }}
{{- end }}

{{/*
API endpoint host: LB address, VIP or a single control-plane node IP.
*/}}
{{- define "capv-cluster.endpointHost" -}}
{{- required "cluster.endpoint.host is required. Set an external load-balancer address, a kube-vip VIP, or the static IP of a single control-plane node." .Values.cluster.endpoint.host }}
{{- end }}

{{/*
API endpoint port.
*/}}
{{- define "capv-cluster.endpointPort" -}}
{{- default 6443 .Values.cluster.endpoint.port | int }}
{{- end }}

{{/*
API endpoint in host:port form (IPv6-safe).
*/}}
{{- define "capv-cluster.endpoint" -}}
{{- $host := include "capv-cluster.endpointHost" . -}}
{{- $port := include "capv-cluster.endpointPort" . | int -}}
{{- if contains ":" $host -}}
{{- printf "[%s]:%d" $host $port -}}
{{- else -}}
{{- printf "%s:%d" $host $port -}}
{{- end -}}
{{- end }}

{{/*
Secret with vCenter credentials. Created by the chart or supplied by the user.
*/}}
{{- define "capv-cluster.credentialsSecretName" -}}
{{- if .Values.vsphere.credentials.existingSecret -}}
{{- .Values.vsphere.credentials.existingSecret -}}
{{- else -}}
{{- printf "%s-vsphere-credentials" (include "capv-cluster.clusterName" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Comma-separated node labels for kubelet --node-labels.
*/}}
{{- define "capv-cluster.nodeLabels" -}}
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
  include "capv-cluster.nodeRegistration" (dict "args" <map> "labels" <map> "taints" <list>)
*/}}
{{- define "capv-cluster.nodeRegistration" -}}
{{- $args := deepCopy (.args | default dict) -}}
{{- $labels := .labels | default dict -}}
{{- if and $labels (not (hasKey $args "node-labels")) -}}
{{- $_ := set $args "node-labels" (include "capv-cluster.nodeLabels" (dict "labels" $labels)) -}}
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
  include "capv-cluster.kubeadmExtraArgs" (dict "args" .Values.kubeadm.apiServer.extraArgs "root" .)
*/}}
{{- define "capv-cluster.kubeadmExtraArgs" -}}
{{- $root := .root -}}
{{- range $k, $v := (.args | default dict) }}
- name: {{ $k }}
  value: {{ tpl (toString $v) $root | quote }}
{{- end }}
{{- end }}

{{/*
VSphereMachineTemplate spec for a group.

Usage:
  include "capv-cluster.machineSpec" (dict "root" . "group" .Values.controlPlane "name" "control-plane")
*/}}
{{- define "capv-cluster.machineSpec" -}}
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
  include "capv-cluster.preKubeadmCommands" (dict "kubeVip" true "extra" <list>)
*/}}
{{- define "capv-cluster.preKubeadmCommands" -}}
{{- $hostname := "{{ ds.meta_data.hostname }}" -}}
- hostnamectl set-hostname "{{ $hostname }}"
- echo "::1         ipv6-localhost ipv6-loopback" > /etc/hosts
- echo "127.0.0.1   localhost" >> /etc/hosts
- echo "127.0.0.1   {{ $hostname }}" >> /etc/hosts
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
  include "capv-cluster.kubeadmFiles" (dict "root" . "kubeVip" true "extraFiles" <list>)
*/}}
{{- define "capv-cluster.kubeadmFiles" -}}
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
{{- define "capv-cluster.validate" -}}
{{- $clusterName := include "capv-cluster.clusterName" . -}}
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
{{- $host := include "capv-cluster.endpointHost" . -}}
{{- $ipv4 := "^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$" -}}
{{- if not (regexMatch $ipv4 $host) -}}
{{- fail "kubeVip.enabled requires cluster.endpoint.host to be an IPv4 VIP address (ARP mode)" -}}
{{- end -}}
{{- if ne (int (include "capv-cluster.endpointPort" .)) 6443 -}}
{{- fail "kubeVip.enabled requires cluster.endpoint.port to be 6443 (kube-vip does not proxy ports)" -}}
{{- end -}}
{{- end -}}
{{- if .Values.ssh.enabled -}}
{{- if not .Values.ssh.authorizedKeys -}}
{{- fail "ssh.enabled=true requires at least one ssh.authorizedKeys entry" -}}
{{- end -}}
{{- end -}}
{{- end }}
